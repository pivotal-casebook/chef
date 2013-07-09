# Author:: Lamont Granquist (<lamont@opscode.com>)
# Copyright:: Copyright (c) 2013 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/mixin/shell_out'
require 'diff/lcs'

class Chef
  class Util
    class Diff
      include Chef::Mixin::ShellOut

      # @todo: to_a, to_s, to_json, inspect defs, accessors for @diff and @error
      # @todo: move coercion to UTF-8 into to_json
      # @todo: replace shellout to diff -u with diff-lcs gem

      def for_output
        # formatted output to a terminal uses arrays of strings and returns error strings
        @diff.nil? ? [ @error ] : @diff
      end

      def for_reporting
        # caller needs to ensure that new files aren't posted to resource reporting
        return nil if @diff.nil?
        @diff.join("\\n")
      end

      def use_tempfile_if_missing(file)
        tempfile = nil
        unless File.exists?(file)
          Chef::Log.debug("file #{file} does not exist to diff against, using empty tempfile")
          tempfile = Tempfile.new("chef-diff")
          file = tempfile.path
        end
        yield file
        unless tempfile.nil?
          tempfile.close
          tempfile.unlink
        end
      end

      def diff(old_file, new_file)
        use_tempfile_if_missing(old_file) do |old_file|
          use_tempfile_if_missing(new_file) do |new_file|
            @error = do_diff(old_file, new_file)
          end
        end
      end

      private

      def do_diff(old_file, new_file)
        if Chef::Config[:diff_disabled]
          return "(diff output suppressed by config)"
        end

        diff_filesize_threshold = Chef::Config[:diff_filesize_threshold]
        diff_output_threshold = Chef::Config[:diff_output_threshold]

        if ::File.size(old_file) > diff_filesize_threshold || ::File.size(new_file) > diff_filesize_threshold
          return "(file sizes exceed #{diff_filesize_threshold} bytes, diff output suppressed)"
        end

        # MacOSX(BSD?) diff will *sometimes* happily spit out nasty binary diffs
        return "(current file is binary, diff output suppressed)" if is_binary?(old_file)
        return "(new content is binary, diff output suppressed)" if is_binary?(new_file)

        begin
          Chef::Log.debug("running: diff -u #{old_file} #{new_file}")
          diff_str = udiff(old_file, new_file)
        rescue Exception => e
          return "Could not determine diff. Error: #{e.message}"
        end

        if !diff_str.empty? && diff_str != "No differences encountered\n"
          if diff_str.length > diff_output_threshold
            return "(long diff of over #{diff_output_threshold} characters, diff output suppressed)"
          else
            diff_str = encode_diff(diff_str)
            @diff = diff_str.split("\n")
            return "(diff available)"
          end
        else
          return "(no diff)"
        end
      end

      def is_binary?(path)
        File.open(path) do |file|
          # XXX: this slurps into RAM, but we should have already checked our diff has a reasonable size
          buff = file.read
          buff = "" if buff.nil?
          begin
            return buff !~ /\A[\s[:print:]]*\z/m
          rescue ArgumentError => e
            return true if e.message =~ /invalid byte sequence/
            raise
          end
        end
      end

      # returns a unified output format diff with 3 lines of context
      def udiff(old_file, new_file)
        diff_str = ""
        file_length_difference = 0

        old_data = IO::readlines(old_file).map { |e| e.chomp }
        new_data = IO::readlines(new_file).map { |e| e.chomp }    
        diffs = ::Diff::LCS.diff(old_data, new_data)
      
        if diffs.empty?
          # if both old_data and new_data are empty, no diff taken.
          # otherwise, the files have identical content.
          unless old_data.empty? && new_data.empty?
            diff_str << "No differences encountered\n"
          end
          return diff_str
        end
        
        # write diff header (standard unified format)
        ft = File.stat(old_file).mtime.localtime.strftime('%Y-%m-%d %H:%M:%S.%N %z')
        diff_str << "--- #{old_file}\t#{ft}\n"
        ft = File.stat(new_file).mtime.localtime.strftime('%Y-%m-%d %H:%M:%S.%N %z')
        diff_str << "+++ #{new_file}\t#{ft}\n"

        # loop over hunks. if a hunk overlaps with the last hunk, join
        # them. otherwise, print out the old one.
        oldhunk = hunk = nil
        diffs.each do |piece|
          begin
            hunk = ::Diff::LCS::Hunk.new(old_data, new_data, piece, 3, file_length_difference)
            file_length_difference = hunk.file_length_difference
          
            next unless oldhunk
            next if hunk.merge(oldhunk)
          
            diff_str << oldhunk.diff(:unified) << "\n"
          ensure
            oldhunk = hunk
          end
        end
        
        diff_str << oldhunk.diff(:unified) << "\n"
        return diff_str
      end

      def encode_diff(diff_str)
        if Object.const_defined? :Encoding  # ruby >= 1.9
          diff_str.encode!('UTF-8', :invalid => :replace, :undef => :replace, :replace => '?')
        end
        return diff_str
      end

    end
  end
end

