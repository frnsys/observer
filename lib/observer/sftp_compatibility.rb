# From Philip Matarese
# http://rubyforge.org/projects/sftp-compat/

module Net
	module SFTP
    class Session
      def mkdir(path)
        @current_path ||= '.'
        method_missing :mkdir, File.join(@current_path, path), {}
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
          handle = open_handle(File.join(@current_path, remotefile), "w")
          file = Kernel.open(localfile)
          file.binmode
          result = write(handle, file.read)

          raise(StandardError, result.message) unless result.code == 0
        ensure
          file.close
          close_handle(handle)
        end
      end

      def delete(path)
        @current_path ||= '.'
        remove File.join(@current_path, path)
      end

      def nlst
        @current_path ||= '.'
        handle = opendir(@current_path)
        list = readdir(handle).map{|f| f.filename}
        close_handle(handle)
        return list
      end
    end
  end
end