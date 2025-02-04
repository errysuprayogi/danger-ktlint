# frozen_string_literal: true

require 'json'

module Danger
  class DangerKtlint < Plugin
    class UnexpectedLimitTypeError < StandardError; end

    class UnsupportedServiceError < StandardError
      def initialize(message = 'Unsupported service! Currently supported services are GitHub, GitLab and BitBucket server.')
        super(message)
      end
    end

    AVAILABLE_SERVICES = [:github, :gitlab, :bitbucket_server]

    # TODO: Lint all files if `filtering: false`
    attr_accessor :filtering

    # Only shows messages for the modified lines.
    attr_accessor :filtering_lines

    attr_accessor :skip_lint, :report_file, :report_files_pattern


    def limit
      @limit ||= nil
    end

    def limit=(limit)
      if limit != nil && limit.integer?
        @limit = limit
      else
        raise UnexpectedLimitTypeError
      end
    end

    # Run ktlint task using command line interface
    # Will fail if `ktlint` is not installed
    # Skip lint task if files changed are empty
    # @return [void]
    # def lint(inline_mode: false)
    def lint(inline_mode: false)
      unless supported_service?
        raise UnsupportedServiceError.new
      end

      # targets = target_files(git.added_files + git.modified_files)
      targets = target_files((git.modified_files - git.deleted_files) + git.added_files)
      results = ktlint_results(targets)
      if results.nil? || results.empty?
        return
      end

      if inline_mode
        send_inline_comments(results, targets)
      else
        send_markdown_comment(results, targets)
      end
    end

    # Comment to a PR by ktlint result json
    #
    # // Sample single ktlint result
    # [
    #   {
    #     "file": "app/src/main/java/com/mataku/Model.kt",
    # 		"errors": [
    # 			{
    # 				"line": 46,
    # 				"column": 1,
    # 				"message": "Unexpected blank line(s) before \"}\"",
    # 				"rule": "no-blank-line-before-rbrace"
    # 			}
    # 		]
    # 	}
    # ]
    def send_markdown_comment(ktlint_results, targets)
      catch(:loop_break) do
        count = 0
        ktlint_results.each do |ktlint_result|
          ktlint_result.each do |result|
            result['errors'].each do |error|
              file_path = relative_file_path(result['file'])
              next unless targets.include?(file_path)

              message = "#{file_html_link(file_path, error['line'])}: #{error['message']}"
              warn(message)
              unless limit.nil?
                count += 1
                if count >= limit
                  throw(:loop_break)
                end
              end
            end
          end
        end
      end
    end

    def send_inline_comments(ktlint_results, targets)
      catch(:loop_break) do
        count = 0
        ktlint_results.each do |ktlint_result|
          ktlint_result.each do |result|
            result['errors'].each do |error|
              file_path = relative_file_path(result['file'])
              # next unless targets.include?(file_path)
              next unless (!filtering && !filtering_lines) || (targets.include? file_path)
              message = error['message']
              line = error['line']
              if filtering_lines
                added_lines = parse_added_line_numbers(git.diff[file_path].patch)
                next unless added_lines.include? line
              end
              warn(message, file: file_path, line: line)
              unless limit.nil?
                count += 1
                if count >= limit
                  throw(:loop_break)
                end
              end
            end
          end
        end
      end
    end

    # Parses git diff of a file and retuns an array of added line numbers.
    def parse_added_line_numbers(diff)
      current_line_number = nil
      added_line_numbers = []
      diff_lines = diff.strip.split("\n")
      diff_lines.each_with_index do |line, index|
        if m = /\+(\d+)(?:,\d+)? @@/.match(line)
          # (e.g. @@ -32,10 +32,7 @@)
          current_line_number = Integer(m[1])
        else
          unless current_line_number.nil?
            if line.start_with?("+")
              # added line
              added_line_numbers.push current_line_number
              current_line_number += 1
            elsif !line.start_with?("-")
              # unmodified line
              current_line_number += 1
            end
          end
        end
      end
      added_line_numbers
    end

    def target_files(changed_files)
      changed_files.select do |file|
        file.end_with?('.kt')
      end
    end

    # Make it a relative path so it can compare it to git.added_files
    def relative_file_path(file_path)
      # file_path.gsub(/#{pwd}\//, '')
      dir = "#{Dir.pwd}/"
      file_path.gsub(dir, "")
    end

    private

    def file_html_link(file_path, line_number)
      file = if danger.scm_provider == :github
               "#{file_path}#L#{line_number}"
             else
               file_path
             end
      scm_provider_klass.html_link(file)
    end

    # `eval` may be dangerous, but it does not accept any input because it accepts only defined as danger.scm_provider
    def scm_provider_klass
      @scm_provider_klass ||= eval(danger.scm_provider.to_s)
    end

    def pwd
      @pwd ||= `pwd`.chomp
    end

    def ktlint_exists?
      system 'which ktlint > /dev/null 2>&1'
    end

    def ktlint_results(targets)
      if skip_lint
        # TODO: Allow XML
        ktlint_result_files.map do |file|
          File.open(file) do |f|
            JSON.load(f)
          end
        end
      else
        unless ktlint_exists?
          fail("Couldn't find ktlint command. Install first.")
          return
        end

        return if targets.empty?

        [JSON.parse(`ktlint #{targets.join(' ')} --reporter=json --relative`)]
      end
    end

    def supported_service?
      AVAILABLE_SERVICES.include?(danger.scm_provider.to_sym)
    end

    def ktlint_result_files
      if !report_file.nil? && !report_file.empty? && File.exists?(report_file)
        [report_file]
      elsif !report_files_pattern.nil? && !report_files_pattern.empty?
        Dir.glob(report_files_pattern)
      else
        fail("Couldn't find ktlint result json file.\nYou must specify it with `ktlint.report_file=...` or `ktlint.report_files_pattern=...` in your Dangerfile.")
      end
    end
  end
end
