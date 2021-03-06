module RVideo # :nodoc:
  module Tools  # :nodoc:

    # AbstractTool is an interface to every transcoder tool class
    # (e.g. ffmpeg, flvtool2). Called by the Transcoder class.
    class AbstractTool

      def self.assign(cmd, options = {})
        tool_name = cmd.split(" ").first
        begin
          tool_class_name = tool_name.underscore.classify
          tool = RVideo::Tools.const_get(tool_class_name).new(cmd, options)
        rescue NameError => e
          raise TranscoderError::UnknownTool,
            "The recipe tried to use #{tool_name.inspect}, " +
            "which expands to #{tool_class_name.inspect}, which does not exist. \n#{e.message}"
        rescue Object => e
          RVideo.logger.info e.message
          raise e
        end
      end


      module InstanceMethods
        # Defines abstract methods in the convention of "format_#{attribute}"
        # which are meant to be redefined by classes including this behavior.
        def self.abstract_attribute_formatter(*names)
          names.map { |n| "format_#{n}" }.each do |name|
            class_eval %{
              def #{name}(params = {})
                raise ParameterError,
                  "The #{self.class} tool has not implemented the :#{name} method."
              end
            }, __FILE__, __LINE__
          end
        end

        abstract_attribute_formatter :resolution, :deinterlace, :fps,
          :video_bit_rate, :video_bit_rate_tolerance,
          :video_bit_rate_min, :video_bit_rate_max,
          :audio_channels, :audio_bit_rate, :audio_sample_rate

        ###

        attr_reader :options, :command, :raw_result, :progress

        def initialize(raw_command, options = {})
          @raw_command = raw_command
          @options = HashWithIndifferentAccess.new(options)
          @command = interpolate_variables(raw_command)
          @raw_result = ""
        end

        def execute
          @output_params = {}
          if block_given? and self.respond_to?(:execute_with_progress)
            execute_with_progress do |progress|
              yield progress if progress != @progress
              @progress = progress
            end
            
            if @progress != 100
              @progress = 100
              yield @progress
            end
          else
            RVideo.logger.info("\nExecuting Command: #{@command}\n")
            @raw_result = do_execute(@command)
          end

          RVideo.logger.info("Result: \n#{@raw_result}")
          parse_result(@raw_result)
        end

        def do_execute(command)
          CommandExecutor::execute_tailing_stderr(command, 500)
        end

        #
        # Magic parameters
        #
        def temp_dir
          if @options['output_file']
            "#{File.dirname(@options['output_file'])}/"
          else
            ""
          end
        end

        ###
        # FPS aka framerate

        def fps
          format_fps(get_fps)
        end

        def get_fps
          inspect_original if @original.nil?
          fps = @options['fps'] || ""
          case fps
          when "copy"
            get_original_fps
          else
            get_specific_fps
          end
        end

        def get_original_fps
          return {} if @original.fps.nil?
          { :fps => @original.fps }
        end

        def get_specific_fps
          { :fps => @options['fps'] }
        end

        ###
        # Resolution

        def deinterlace
          format_deinterlace(get_deinterlace)
        end

        def get_deinterlace
          { :deinterlace => @options['deinterlace'] ? true : false }
        end

        def resolution
          format_resolution(get_resolution)
        end

        def get_resolution
          inspect_original if @original.nil?

          case @options['resolution']
          when "copy"      then get_original_resolution
          when "width"     then get_fit_to_width_resolution
          when "height"    then get_fit_to_height_resolution
          when "letterbox" then get_letterbox_resolution
          else
            if @options["width"] and not @options["height"]
              get_fit_to_width_resolution
            elsif @options["height"] and not @options["width"]
              get_fit_to_height_resolution
            elsif @options["width"] and @options["height"]
              get_specific_resolution
            else
              get_original_resolution
            end
          end
        end

        def resolution_and_padding
          format_resolution(get_resolution_and_padding)
        end

        def resolution_keep_aspect_ratio
          resolution = get_resolution_and_padding
          resolution.delete(:letterbox)
          format_resolution(resolution)
        end

        def get_resolution_and_padding(out_w = @options["width"], out_h = @options["height"])
          # Calculate resolution and any padding
          out_w = out_w.to_f
          out_h = out_h.to_f
          
          resolution = { :scale => { :width => out_w, :height => out_h } }
          
          in_w = original.width.to_f
          in_h = original.height.to_f

          if(in_w <= 0 || in_h <= 0)
            aspect= out_w / out_h
          else
            aspect = in_w / in_h
          end

          aspect_inv = 1 / aspect
          
          width =  out_w - (out_w % 2)
          height = (width / aspect.to_f).to_i
          height -= (height % 2)

          resolution[:scale][:width] = width
          resolution[:scale][:height] = height
          
          # Keep the video's original width if the height
          if height > out_h
            even_out_h = out_h - (out_h % 2)
            width = (even_out_h / aspect_inv.to_f).to_i
            width -= width % 2
            
            resolution[:scale][:width] = width
            resolution[:scale][:height] = even_out_h
            # Otherwise letterbox it
          elsif height < out_h 
            width_letterbox = out_w - (out_w % 2)
            height_letterbox = out_h - (out_h % 2)
            
            resolution[:letterbox] ||= {}
            resolution[:letterbox][:width] = width_letterbox
            resolution[:letterbox][:height] = height_letterbox
          end
        
          return resolution
        rescue
          RVideo.logger.info "Couldn't do w/h to caculate aspect. Just using the output resolution now."
          return resolution
        end

        def get_fit_to_width_resolution
          w = @options['width']

          raise TranscoderError::ParameterError,
            "invalid width of '#{w}' for fit to width" unless valid_dimension?(w)

          h = calculate_height(@original.width, @original.height, w)

          { :scale => { :width => w, :height => h } }
        end

        def get_fit_to_height_resolution
          h = @options['height']

          raise TranscoderError::ParameterError,
            "invalid height of '#{h}' for fit to height" unless valid_dimension?(h)

          w = calculate_width(@original.width, @original.height, h)

          { :scale => { :width => w, :height => h } }
        end

        def get_letterbox_resolution
          lw = @options['width'].to_i
          lh = @options['height'].to_i

          raise TranscoderError::ParameterError,
            "invalid width of '#{lw}' for letterbox" unless valid_dimension?(lw)
          raise TranscoderError::ParameterError,
            "invalid height of '#{lh}' for letterbox" unless valid_dimension?(lh)

          w = calculate_width(@original.width, @original.height, lh)
          h = calculate_height(@original.width, @original.height, lw)

          if w > lw
            w = lw
            h = calculate_height(@original.width, @original.height, lw)
          else
            h = lh
            w = calculate_width(@original.width, @original.height, lh)
          end

          { :scale     => { :width => w,  :height => h  },
            :letterbox => { :width => lw, :height => lh } }
        end

        def get_original_resolution
          { :scale => { :width => @original.width, :height => @original.height } }
        end

        def get_specific_resolution
          w = @options['width']
          h = @options['height']

          raise TranscoderError::ParameterError,
            "invalid width of '#{w}' for specific resolution" unless valid_dimension?(w)
          raise TranscoderError::ParameterError,
            "invalid height of '#{h}' for specific resolution" unless valid_dimension?(h)

          { :scale => { :width => w, :height => h } }
        end

        def calculate_width(ow, oh, h)
          w = ((ow.to_f / oh.to_f) * h.to_f).to_i
          (w.to_f / 16).round * 16
        end

        def calculate_height(ow, oh, w)
          h = (w.to_f / (ow.to_f / oh.to_f)).to_i
          (h.to_f / 16).round * 16
        end

        def valid_dimension?(dim)
          dim.to_i > 0
        end

        ###
        # Audio channels

        def audio_channels
          format_audio_channels(get_audio_channels)
        end

        def get_audio_channels
          channels = @options['audio_channels'] || ""
          case channels
          when "stereo"
            get_stereo_audio
          when "mono"
            get_mono_audio
          else
            {}
          end
        end

        def get_stereo_audio
          { :channels => "2" }
        end

        def get_mono_audio
          { :channels => "1" }
        end

        def get_specific_audio_bit_rate
          { :bit_rate => @options['audio_bit_rate'] }
        end

        def get_specific_audio_sample_rate
          { :sample_rate => @options['audio_sample_rate'] }
        end

        ###
        # Audio bit rate

        def audio_bit_rate
          format_audio_bit_rate(get_audio_bit_rate)
        end

        def get_audio_bit_rate
          bit_rate = @options['audio_bit_rate'] || ""
          case bit_rate
          when ""
            {}
          else
            get_specific_audio_bit_rate
          end
        end

        ###
        # Audio sample rate

        def audio_sample_rate
          format_audio_sample_rate(get_audio_sample_rate)
        end

        def get_audio_sample_rate
          sample_rate = @options['audio_sample_rate'] || ""
          case sample_rate
          when ""
            {}
          else
            get_specific_audio_sample_rate
          end
        end

        ###
        # Video quality

        def video_quality
          format_video_quality(get_video_quality)
        end

        def get_video_quality
          quality = @options['video_quality'] || 'medium'

          { :video_quality => quality }.
            merge!(get_fps).
            merge!(get_resolution).
            merge!(get_video_bit_rate)
        end

        def video_bit_rate
          format_video_bit_rate(get_video_bit_rate)
        end

        def get_video_bit_rate
          { :video_bit_rate => @options["video_bit_rate"] }
        end

        def video_bit_rate_tolerance
          format_video_bit_rate_tolerance(get_video_bit_rate_tolerance)
        end

        def get_video_bit_rate_tolerance
          { :video_bit_rate_tolerance => @options["video_bit_rate_tolerance"] }
        end

        def video_bit_rate_min
          format_video_bit_rate_min(get_video_bit_rate_min)
        end

        def get_video_bit_rate_min
          { :video_bit_rate_min => @options["video_bit_rate_min"] }
        end

        def video_bit_rate_max
          format_video_bit_rate_max(get_video_bit_rate_max)
        end

        def get_video_bit_rate_max
          { :video_bit_rate_max => @options["video_bit_rate_max"] }
        end

        def original
          inspect_original unless @original
          @original
        end

        def original=(value)
          @original=value
        end

        
        private

        VARIABLE_INTERPOLATION_SCAN_PATTERN = /[^\\]\$[-_a-zA-Z]+\$/
        SCALE_PATTERN = /[^\\](\$scale_([0-9]+)x([0-9]+)\$)/
        ADAPTIVE_SCALE_PATTERN = /[^\\](\$scale_([0-9]+)x([0-9]+)_or_([0-9]+)x([0-9]+)\$)/
                
        def interpolate_variables(raw_command)
          raw_command.scan(VARIABLE_INTERPOLATION_SCAN_PATTERN).each do |match|
            match = match[0..0] == "$" ? match : match[1..(match.size - 1)]
            match.strip!

            value = if ["$input_file$", "$output_file$"].include?(match)
              matched_variable(match).to_s.shell_quoted
            else
              matched_variable(match).to_s
            end
            
            raw_command.gsub!(match, value)
          end

          raw_command.scan(ADAPTIVE_SCALE_PATTERN).each do |match, width, height, width2, height2|
            
            r = original.ratio.to_f
            aspect_4_3 = 4.0/3.0
            
            if (r > aspect_4_3)
              value = format_resolution(get_resolution_and_padding(width2, height2))
            else
              value = format_resolution(get_resolution_and_padding(width, height))
            end
            
            raw_command.gsub!(match, value)
          end
                    
         raw_command.scan(SCALE_PATTERN).each do |match, width, height|
           value = format_resolution(get_resolution_and_padding(width, height))
           raw_command.gsub!(match, value)
         end

        raw_command.gsub("\\$", "$")
      end

      #
      # Strip the $s. First, look for a supplied option that matches the
      # variable name. If one is not found, look for a method that matches.
      # If not found, raise ParameterError exception.
      #

      def matched_variable(match)
        variable_name = match.gsub("$","")
        if self.respond_to? variable_name
          self.send(variable_name)
        elsif @options.key?(variable_name)
          @options[variable_name]
        else
          raise TranscoderError::ParameterError,
            "command is looking for the #{variable_name} parameter, but it was not provided. (Command: #{@raw_command})"
        end
      end


      def inspect_original
        @original = Inspector.new(:file => options[:input_file])
      end
      
    end # InstanceMethods
  end

end
end