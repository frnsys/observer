# This mirrors the methods of Ruby's Net::FTP module.
# From Philip Matarese
# http://rubyforge.org/projects/sftp-compat/
# Updated by Francis Tseng

module Net
	module SFTP
    class Session
      def mkdir(path)
        @current_path ||= '.'
        mkdir!( File.join(@current_path, path) )
      end

      def rmdir(path)
        @current_path ||= '.'
        method_missing :rmdir, File.join(@current_path, path)
      end

      def chdir(path)
        @current_path ||= '.'
        if path == '..'
          @current_path.slice!(@current_path.rindex('/').to_i, @current_path.size)
        else
          @current_path = File.join(@current_path, path)
        end
      end

      def putbinaryfile(localfile, remotefile)
        @current_path ||= '.'

        begin
          handle = open(File.join(@current_path, remotefile), "w")
          file = Kernel.open(localfile)
          file.binmode
          result = write(handle, 0, file.read)

          # raise(StandardError, result.message) unless result.code == 0
        ensure
          file.close
          close(handle)
        end
      end

      def delete(path)
        @current_path ||= '.'
        remove File.join(@current_path, path)
      end

      def nlst
        @current_path ||= '.'
        #handle = opendir(@current_path)
				handle = @current_path
        list = dir.entries(handle).map{|f| f.name}
        close(handle)
        return list
      end

			def mtime(path)
				@current_path ||= '.'
				return stat!( File.join(@current_path, path) ).mtime
			end
    end
  end
end