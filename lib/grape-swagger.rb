require 'kramdown'

module Grape
  class API
    class << self
      attr_reader :combined_routes

      def add_swagger_documentation(options={})
        documentation_class = create_documentation_class

        documentation_class.setup({:target_class => self}.merge(options))
        mount(documentation_class)

        @combined_routes = {}
        routes.each do |route|
          route_match = route.route_path.split(route.route_prefix).last.match('\/([\w|-]*?)[\.\/\(]')
          next if route_match.nil?
          resource = route_match.captures.first
          next if resource.empty?
          resource.downcase!
          @combined_routes[resource] ||= []

          unless @@hide_documentation_path and route.route_path.include? @@mount_path
            @combined_routes[resource] << route
          end
        end

        split_in = options[:split_in]

        if @combined_routes && !@combined_routes.empty? && split_in
          split_routes(@combined_routes, split_in)
        end

      end

      private

      def split_routes(combined_routes, split_in)
        if !split_in.is_a?(Array) && !split_in.is_a?(Hash)
          puts "The param split_in is not valid. Must be an Array or Hash"
          return
        end

        new_map = Hash.new
        split_in.each do |title, group|

          title = title.to_s

          combined_routes.each do |key, route|
            if key == "api-docs"
              next
            end

            new_key = title.gsub("/", "")

            aux = route.select do |item|
              path = item.to_param.to_s.split("path=")[1]
              matched = path.match(title)

              matched
            end

            route.delete_if do |item|
              included = aux.include?(item)

              included
            end

            if (!new_map[new_key])
              new_map[new_key] = aux
            else
              new_map[new_key] = new_map[new_key].concat(aux)
            end
          end
        end
        keys = new_map.keys.reverse
        values = new_map.values.reverse

        keys.each_with_index do |key, index|
          combined_routes[key] = values[index]
        end
      end # end split_in

      def create_documentation_class

        Class.new(Grape::API) do
          class << self
            def name
              @@class_name
            end
          end

          def self.setup(options)
            defaults = {
              :target_class => nil,
              :mount_path => '/swagger_doc',
              :base_path => nil,
              :api_version => '0.1',
              :markdown => false,
              :hide_documentation_path => false,
              :hide_format => false,
              :models => []
            }
            options = defaults.merge(options)

            target_class = options[:target_class]
            @@mount_path = options[:mount_path]
            @@class_name = options[:class_name] || options[:mount_path].gsub('/','')
            @@markdown = options[:markdown]
            @@hide_documentation_path = options[:hide_documentation_path]
            @@hide_format = options[:hide_format]
            api_version = options[:api_version]
            base_path = options[:base_path]

            desc 'Swagger compatible API description'
            get @@mount_path do
              header['Access-Control-Allow-Origin'] = '*'
              header['Access-Control-Request-Method'] = '*'
              routes = target_class::combined_routes

              if @@hide_documentation_path
                routes.reject!{ |route, value| "/#{route}/".index(parse_path(@@mount_path, nil) << '/') == 0 }
              end

              routes_array = routes.keys.map { |local_route|
                next if routes[local_route].all? { |route| route.route_hidden }
                { :path => "#{parse_path(route.route_path.gsub('(.:format)', ''),route.route_version)}/#{local_route}#{@@hide_format ? '' : '.{format}'}" }
              }.compact

              if options[:split_in]
                configure_route_descriptions(routes_array, options)
              end

              {
                apiVersion: api_version,
                swaggerVersion: "1.1",
                basePath: parse_base_path(base_path, request),
                operations:[],
                apis: routes_array
              }
            end

            desc 'Swagger compatible API description for specific API', :params =>
              {
                "name" => { :desc => "Resource name of mounted API", :type => "string", :required => true },
              }
            get "#{@@mount_path}/:name" do
              header['Access-Control-Allow-Origin'] = '*'
              header['Access-Control-Request-Method'] = '*'

              models = []
              routes = target_class::combined_routes[params[:name]]
              if routes
                routes_array = routes.map {|route|
                  next if route.route_hidden
                  notes = route.route_notes && @@markdown ? Kramdown::Document.new(strip_heredoc(route.route_notes)).to_html : route.route_notes
                  http_codes = parse_http_codes route.route_http_codes
                  models << route.route_entity if route.route_entity
                  operations = {
                      :notes => notes,
                      :summary => route.route_description || '',
                      :nickname   => route.route_method + route.route_path.gsub(/[\/:\(\)\.]/,'-'),
                      :httpMethod => route.route_method,
                      :parameters => parse_header_params(route.route_headers) +
                        parse_params(route.route_params, route.route_path, route.route_method)
                  }
                  operations.merge!({:responseClass => route.route_entity.to_s.split('::')[-1]}) if route.route_entity
                  operations.merge!({:errorResponses => http_codes}) unless http_codes.empty?
                  {
                    :path => parse_path(route.route_path, api_version),
                    :operations => [operations]
                  }
                }.compact
              else
                routes_array = []
              end

              api_description = {
                apiVersion: api_version,
                swaggerVersion: "1.1",
                basePath: parse_base_path(base_path, request),
                resourcePath: "",
                apis: routes_array
              }
              api_description[:models] = parse_entity_models(models) unless models.empty?
              api_description
            end
          end


          helpers do

            def configure_route_descriptions(routes_array, options)
              split_in = options[:split_in]

              routes_array.each do | route |
                path = get_reduce_path(route, options)

                if split_in.is_a?(Array)
                  index = split_in.find_index(path.to_sym)
                  desc = index ? split_in[index] : path.capitalize
                else
                  desc = split_in[path.to_sym] || path.capitalize
                end

                route[:description] = desc
              end

              if options[:to_sort]
                routes_array.sort! { | a, b |
                  pathA = get_reduce_path(a, options)
                  pathB = get_reduce_path(b, options)

                  pathA <=> pathB
                }
              end

            end

            def get_reduce_path(route, options)
              path = route[:path]
              path = path.to_s.gsub(options[:mount_path], "")
              path = path.to_s.gsub("/", "")
              path
            end

            def parse_params(params, path, method)
              if params
                params.map do |param, value|
                  value[:type] = 'file' if value.is_a?(Hash) && value[:type] == 'Rack::Multipart::UploadedFile'

                  dataType = value.is_a?(Hash) ? (value[:type] || 'String').to_s : 'String'
                  description = value.is_a?(Hash) ? value[:desc] || value[:description] : ''
                  required = value.is_a?(Hash) ? !!value[:required] : false
                  paramType = path.include?(":#{param}") ? 'path' : (method == 'POST' || method == 'PUT') ? 'body' : 'query'
                  name = (value.is_a?(Hash) && value[:full_name]) || param

                  if path.include?("/:#{param}")
                    required = true
                  end

                  {
                    paramType: paramType,
                    name: name,
                    description: description,
                    dataType: dataType,
                    required: required
                  }
                end
              else
                []
              end
            end

            def parse_header_params(params)
              if params
                params.map do |param, value|
                  dataType = 'String'
                  description = value.is_a?(Hash) ? value[:description] : ''
                  required = value.is_a?(Hash) ? !!value[:required] : false
                  paramType = "header"
                  {
                    paramType: paramType,
                    name: param,
                    description: description,
                    dataType: dataType,
                    required: required
                  }
                end
              else
                []
              end
            end

            def parse_path(path, version)
              # adapt format to swagger format
              parsed_path = path.gsub '(.:format)', ( @@hide_format ? '' : '.{format}')
              # This is attempting to emulate the behavior of
              # Rack::Mount::Strexp. We cannot use Strexp directly because
              # all it does is generate regular expressions for parsing URLs.
              # TODO: Implement a Racc tokenizer to properly generate the
              # parsed path.
              parsed_path = parsed_path.gsub(/:([a-zA-Z_]\w*)/, '{\1}')
              # add the version
              version ? parsed_path.gsub('{version}', version) : parsed_path
            end

            def parse_entity_models(models)
              result = {}
              models.each do |model|
                name = model.to_s.split('::')[-1]
                result[name] = {
                  id: name,
                  name: name,
                  properties: model.documentation
                }
              end
              result
            end

            def parse_http_codes codes
              codes ||= {}
              codes.collect do |k, v|
                { code: k, reason: v }
              end
            end

            def try(*a, &b)
              if a.empty? && block_given?
                yield self
              else
                public_send(*a, &b) if respond_to?(a.first)
              end
            end

            def strip_heredoc(string)
              indent = string.scan(/^[ \t]*(?=\S)/).min.try(:size) || 0
              string.gsub(/^[ \t]{#{indent}}/, '')
            end

            def parse_base_path(base_path, request)
              (base_path.is_a?(Proc) ? base_path.call(request) : base_path) || request.base_url
            end
          end
        end
      end
    end
  end
end
