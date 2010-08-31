require 'rubygems'
require 'nokogiri'
require 'uri/http'

module Readability
  class Document
    IMAGE_AREA_THRESHOLD = 80000 # Every 80,000 pixels contributes TEXT_LENGTH_THRESHOLD to the node length score
    TEXT_LENGTH_THRESHOLD = 25
    RETRY_LENGTH = 250

    attr_accessor :options, :html

    def initialize(input, options = {})
      @input = input
      @options = options
      make_html
    end

    def make_html
      @html = Nokogiri::HTML(@input, nil, 'UTF-8')
    end

    REGEXES = {
        :unlikelyCandidatesRe => /combx|comment|disqus|foot|header|menu|meta|nav|rss|shoutbox|sidebar|sponsor/i,
        :okMaybeItsACandidateRe => /and|article|body|column|main/i,
        :positiveRe => /article|body|content|entry|hentry|page|pagination|post|text/i,
        :negativeRe => /combx|comment|contact|foot|footer|footnote|link|media|meta|promo|related|scroll|shoutbox|sponsor|tags|widget/i,
        :divToPElementsRe => /<(a|blockquote|dl|div|img|ol|p|pre|table|ul)/i,
        :replaceBrsRe => /(<br[^>]*>[ \n\r\t]*){2,}/i,
        :replaceFontsRe => /<(\/?)font[^>]*>/i,
        :trimRe => /^\s+|\s+$/,
        :normalizeRe => /\s{2,}/,
        :killBreaksRe => /(<br\s*\/?>(\s|&nbsp;?)*){1,}/,
        :videoRe => /http:\/\/(www\.)?(youtube|vimeo)\.com/i
    }

    def content(remove_unlikely_candidates = true)
      @html.css("script, style").each { |i| i.remove }

      remove_unlikely_candidates! if remove_unlikely_candidates
      transform_misused_divs_into_paragraphs!
      candidates = score_paragraphs(options[:min_text_length] || TEXT_LENGTH_THRESHOLD)
      best_candidate = select_best_candidate(candidates)
      article = get_article(candidates, best_candidate)

      cleaned_article = sanitize(article, candidates, options)
      debug "finished cleaning article"
      if remove_unlikely_candidates && article.text.strip.length < (options[:retry_length] || RETRY_LENGTH)
        debug "Branch 1"
        make_html
        content(false)
      else
        debug "Branch 2"
        cleaned_article
      end
    end

    def get_article(candidates, best_candidate)
      # Now that we have the top candidate, look through its siblings for content that might also be related.
      # Things like preambles, content split by ads that we removed, etc.

      sibling_score_threshold = [10, best_candidate[:content_score] * 0.2].max
      output = Nokogiri::XML::Node.new('div', @html)
      best_candidate[:elem].parent.children.each do |sibling|
        append = false
        append = true if sibling == best_candidate[:elem]
        append = true if candidates[sibling] && candidates[sibling][:content_score] >= sibling_score_threshold

        if sibling.name.downcase == "p"
          link_density = get_link_density(sibling)
          node_content = sibling.text
          node_length = node_content.length

          if node_length > 80 && link_density < 0.25
            append = true
          elsif node_length < 80 && link_density == 0 && node_content =~ /\.( |$)/
            append = true
          end
        end

        if append
          sibling.name = "div" unless %w[div p].include?(sibling.name.downcase)
          output << sibling
        end
      end

      output
    end

    def select_best_candidate(candidates)
      sorted_candidates = candidates.values.sort { |a, b| b[:content_score] <=> a[:content_score] }

      debug("Top 5 canidates:")
      sorted_candidates[0...5].each do |candidate|
        debug("Candidate #{candidate[:elem].name}##{candidate[:elem][:id]}.#{candidate[:elem][:class]} with score #{candidate[:content_score]}")
      end

      best_candidate = sorted_candidates.first || { :elem => @html.css("body").first, :content_score => 0 }
      debug("Best candidate #{best_candidate[:elem].name}##{best_candidate[:elem][:id]}.#{best_candidate[:elem][:class]} with score #{best_candidate[:content_score]}")

      best_candidate
    end

    def get_link_density(elem)
      link_length = elem.css("a").map {|i| i.text}.join("").length
      text_length = elem.text.length
      link_length / text_length.to_f
    end

    def score_paragraphs(min_content_score)
      candidates = {}
      @html.css("p,td,li").each do |elem|
        parent_node = elem.parent
        grand_parent_node = parent_node.respond_to?(:parent) ? parent_node.parent : nil
        inner_text = elem.text
        content_length_score = inner_text.length

        # Threshold for pure image content is eq. to IMAGE_AREA_THRESHOLD
        if options[:score_images]
          per_pixel_contribution = min_content_score.to_f/IMAGE_AREA_THRESHOLD;
          node_image_contribution = 0
          elem.css("img").each do |e|
            unless e[:width].blank? or e[:height].blank?
              node_image_contribution += [e[:width].to_i*e[:height].to_i*per_pixel_contribution, 8*min_content_score].min
            end
          end
          content_length_score += node_image_contribution
          debug "Images contributed #{node_image_contribution} pts to #{elem.name}##{elem[:id]}.#{elem[:class]}"
        end

        # Remove paragraph if shorter than min text threshold, including images
        next if content_length_score < min_content_score

        candidates[parent_node] ||= score_node(parent_node)
        candidates[grand_parent_node] ||= score_node(grand_parent_node) if grand_parent_node

        content_score = 1
        content_score += inner_text.split(',').length
        content_score += [(inner_text.length / 100).to_i, 3].min
        content_score += node_image_contribution/5
        
        candidates[parent_node][:content_score] += content_score
        candidates[grand_parent_node][:content_score] += content_score / 2.0 if grand_parent_node
      end

      # Scale the final candidates score based on link density. Good content should have a
      # relatively small link density (5% or less) and be mostly unaffected by this operation.
      candidates.each do |elem, candidate|
        candidate[:content_score] = candidate[:content_score] * (1 - get_link_density(elem))
      end

      candidates
    end

    def class_weight(e)
      weight = 0
      if e[:class] && e[:class] != ""
        if e[:class] =~ REGEXES[:negativeRe]
          weight -= 25
        end

        if e[:class] =~ REGEXES[:positiveRe]
          weight += 25
        end
      end

      if e[:id] && e[:id] != ""
        if e[:id] =~ REGEXES[:negativeRe]
          weight -= 25
        end

        if e[:id] =~ REGEXES[:positiveRe]
          weight += 25
        end
      end

      weight
    end

    def score_node(elem)
      content_score = class_weight(elem)
      case elem.name.downcase
        when "div":
          content_score += 5
        when "blockquote":
          content_score += 3
        when "form":
          content_score -= 3
        when "th":
          content_score -= 5
      end
      { :content_score => content_score, :elem => elem }
    end

    def debug(str)
      puts str if options[:debug]
    end

    def remove_unlikely_candidates!
      @html.css("*").each do |elem|
        str = "#{elem[:class]}#{elem[:id]}"
        if str =~ REGEXES[:unlikelyCandidatesRe] && str !~ REGEXES[:okMaybeItsACandidateRe] && elem.name.downcase != 'body'
          debug("Removing unlikely candidate - #{str}")
          elem.remove
        end
      end
    end

    def transform_misused_divs_into_paragraphs!
      @html.css("*").each do |elem|
        if elem.name.downcase == "div"
          # transform <div>s that do not contain other block elements into <p>s
          if elem.inner_html !~ REGEXES[:divToPElementsRe]
            debug("Altering div(##{elem[:id]}.#{elem[:class]}) to p");
            elem.name = "p"
          end
        else
          # wrap text nodes in p tags
#          elem.children.each do |child|
#            if child.text?
##              debug("wrapping text node with a p")
#              child.swap("<p>#{child.text}</p>")
#            end
#          end
        end
      end
    end

    def sanitize(node, candidates, options = {})
      node.css("h1, h2, h3, h4, h5, h6").each do |header|
        header.remove if class_weight(header) < 0 || get_link_density(header) > 0.33
      end

      node.css("form, object, iframe, embed").each do |elem|
        elem.remove
      end

      # remove empty <p> and <div> tags
      node.css("p,div").each do |elem|
        elem.remove if elem.content.strip.empty?
      end

      # Conditionally clean <table>s, <ul>s, and <div>s
      node.css("table, ul, div").each do |el|
        weight = class_weight(el)
        content_score = candidates[el] ? candidates[el][:content_score] : 0
        name = el.name.downcase

        if weight + content_score < 0
          el.remove
          debug("Conditionally cleaned #{name}##{el[:id]}.#{el[:class]} with weight #{weight} and content score #{content_score} because score + content score was less than zero.")
        elsif el.text.count(",") < 10
          counts = %w[p img li a embed input].inject({}) { |m, kind| m[kind] = el.css(kind).length; m }
          counts["li"] -= 100

          content_length = el.text.strip.length  # Count the text length excluding any surrounding whitespace
          link_density = get_link_density(el)
          to_remove = false
          reason = ""

          if counts["img"] > counts["p"]
            reason = "too many images"
            # If we allow weighting for images, lets be lenient
            if options[:score_images]
              to_remove = true if counts["img"] > (counts["p"] * 2)
            else
              to_remove = true
            end
          elsif counts["li"] > counts["p"] && name != "ul" && name != "ol"
            reason = "more <li>s than <p>s"
            to_remove = true
          elsif counts["input"] > (counts["p"] / 3).to_i
            reason = "less than 3x <p>s than <input>s"
            to_remove = true
          elsif content_length < (options[:min_text_length] || TEXT_LENGTH_THRESHOLD) && (counts["img"] == 0 || counts["img"] > 2)
            reason = "too short a content length without a single image"
            to_remove = true
          elsif weight < 25 && link_density > 0.2
            reason = "too many links for its weight (#{weight})"
            to_remove = true
          elsif weight >= 25 && link_density > 0.5
            reason = "too many links for its weight (#{weight})"
            to_remove = true
          elsif (counts["embed"] == 1 && content_length < 75) || counts["embed"] > 1
            reason = "<embed>s with too short a content length, or too many <embed>s"
            to_remove = true
          end

          if to_remove
            debug("Conditionally cleaned #{name}##{el[:id]}.#{el[:class]} with weight #{weight} and content score #{content_score} because it has #{reason}.")
            el.remove
          end
        end
      end

      # We'll sanitize all elements using a whitelist
      base_whitelist = @options[:tags] || %w[div p]

      # Use a hash for speed (don't want to make a million calls to include?)
      whitelist = Hash.new
      base_whitelist.each {|tag| whitelist[tag] = true }
      ([node] + node.css("*")).each do |el|

        # If element is in whitelist, delete all its attributes
        if whitelist[el.node_name]
          el.attributes.each do |a, x|
            el.delete(a) unless @options[:attributes] && @options[:attributes].include?(a.to_s)
            if options[:sanitize_links] and (a == "href" or a == "src")
              el.set_attribute a, resolve_relative_url(el.attribute(a).value)
              unless validates_url el.attribute(a)
                debug "Removed invalid URL: #{el.attribute a}"
                el.delete a
                break
              end
            end
          end
          debug "set rel"
          if el and el.node_name == "a" and options[:sanitize_links]
            el.set_attribute "rel", "nofollow"
          end
          debug "check for empty a or img"
          if el and (el.keys.length == 0 or el.keys == ["rel"])
            # Empty a or img
            if el.content.strip.empty?
              debug "removing empty el"
              el.remove
            else
              debug "swapping empty el"
              el.swap(el.text)
            end
          end
        else
          # Otherwise, replace the element with its contents
          el.swap(el.text)
        end
        debug "FINISHED LOOP"
      end

      # Get rid of duplicate whitespace
      node.to_html.gsub(/[\r\n\f]+/, "\n" ).gsub(/[\t ]+/, " ").gsub(/&nbsp;/, " ")
      debug "RETURNING FROM SANITIZE"
    end
    
    def resolve_relative_url(value)
      debug "Entered resolve_relative_url with value: #{value.inspect}"
      unless value.blank? or value.index('http://')==0 or options[:resolve_relative_urls_with_path].blank?
        debug "Entered branch 1"
        begin
          source = URI.parse options[:resolve_relative_urls_with_path]
          source_root = "#{source.scheme}://"
          source_root += "#{source.userinfo}@" unless source.userinfo.nil?
          source_root += "#{source.host}"
          source_root += ":#{source.port}" unless source.port == 80
          
          dir_path = source.path.split("/")
          dir_path.pop unless (source.path.last == "/")
          dir_path = "#{source_root}#{dir_path.join '/'}/"
          
          debug "source root: #{source_root}, dir_path = #{dir_path}"
          
          # Determine path type
          if value.index('/') == 0
            debug "root path"
            # Relative to Root
            value = source_root + value
          elsif value.index('http://').nil?
            debug "relative to directory"
            # Either malformed or relative to directory
            value = (dir_path + value) if validates_url(dir_path + value)
          end
        rescue => err
          debug "Error: #{err}"
        end
      end
      debug "returning #{value}"
      value
    end
    
    def validates_url(value)
      begin
        uri = URI.parse(value)

        if !%w[http https].include?(uri.scheme)
          raise(URI::InvalidURIError)
        end

        if [:scheme, :host].any? { |i| uri.send(i).blank? }
          raise(URI::InvalidURIError)
        end

      rescue
        return false
      end
      return true
    end

  end
end
