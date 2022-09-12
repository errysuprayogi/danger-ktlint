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

    # Enable ktlint auto correction and put suggestion on inline file change
    attr_accessor :correction

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
        warning_count = 0
        ktlint_results.each do |ktlint_result|
          ktlint_result.each do |result|
            file_name = relative_file_path(result['file'])
            if correction and ktlint_exists? and file_name.end_with?('.kt')
              file_path = "#{Dir.pwd}/#{file_name}"
              printf("run correction " + file_path + "\n")
              system "ktlint --format #{file_path}"
              diff = `git diff #{file_path}`
              changes = parse_correction(diff)
            end

            filtered_errors = Hash.new
            message = Array.new
            result['errors'].each do |error|
              next unless (!filtering && !filtering_lines) || (targets.include? file_name)
              line = error['line']
              if filtered_errors.has_key? line
                message.push error['message'] unless message.include? error['message']
              else
                message = [error['message']]
              end
              filtered_errors[line] = message * " and "
            end

            line_check = 0
            filtered_errors.each do |line, error|
              found = false
              suggestion = nil
              start_line = line
              last_line = line
              changes.each do |key, val|
                if key.include? line
                  suggestion = val
                  start_line = key[0]
                  last_line = key.last
                  found = true
                end
              end
              if filtering_lines
                added_lines = parse_added_line_numbers(git.diff[file_name].patch)
                next unless added_lines.include? line
              end
              warning_count += 1
              next if line_check == start_line
              options = { start_line: start_line, line: last_line, side: "RIGHT", start_side: "RIGHT" }
              warn(error, file: file_name, line: line, extras: options, comment: suggestion)
              line_check = start_line
              unless limit.nil?
                count += 1
                if count >= limit
                  throw(:loop_break)
                end
              end
            end
          end
        end
        if warning_count > 0
          warn("We found code style issue in your changes please check the suggestion or re-format the code using [Ktlint](https://pinterest.github.io/ktlint/ \"Ktlint Homepage\")")
        end
      end
    end

    def generate_table(error)
      table = "<table>
                <tbody>
                  <tr>
                    <td>:warning:</td>
                    <td width=\"100%\">#{error}</td>
                  </tr>
                </tbody>
              </table>

"
      table
    end

    #Parse git diff of a correction file and return an array of string suggestion code
    def parse_correction(diff)
      current_line_number = nil
      modified_line = nil
      modified_code = nil
      changes = Hash.new
      diff_lines = diff.strip.split("\n")
      diff_lines.each_with_index do |line, index|
        if m = /\-(\d+)(?:,\d+)?/.match(line)
          # (e.g. @@ -32,10 +32,7 @@)
          current_line_number = Integer(m[1])
          modified_code = []
          modified_line = []
        else
          unless current_line_number.nil?
            if line.start_with?('-')
              # deleted line
              modified_code = []
              modified_line.push current_line_number unless modified_line.include? current_line_number
              current_line_number += 1
            elsif line.start_with?('+')
              # added line
              modified_code.push line[1..line.length]
              line_number = (current_line_number - 1)
              modified_line.push line_number unless modified_line.include? line_number
            else
              # unmodified line
              unless not (modified_line.length > 0)
                changes[modified_line] = modified_code * "\n"
                modified_line = []
                modified_code = []
              end
              current_line_number += 1
            end
          end
        end
      end
      changes.each do |result|
        p result
      end
      changes
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
