# This mirrors the methods of Ruby's Net::FTP module.
# Originally by Philip Matarese
# http://rubyforge.org/projects/sftp-compat/
# Updated by Francis Tseng

module Net
	module SFTP
    class Session
      def mkdir(path)
        @current_path ||= '.'
				wait_for( request :mkdir, File.join(@current_path, path), {} )
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

			def getbinaryfile(remotefile, localfile = File.basename(remotefile))
				download!( remotefile, localfile )
			end

      def putbinaryfile(localfile, remotefile)
				sftp.upload!( localfile, remotefile )
      end

      def delete(path)
        @current_path ||= '.'
        remove File.join(@current_path, path)
      end

      def nlst(path = '.')
        @current_path ||= '.'
				handle = File.join(@current_path, path)
				begin
					list = dir.entries(handle).map{|f| f.name}
				rescue
					list = [handle]
				end
        close(handle)
        return list
      end

			def mtime(path)
				@current_path ||= '.'
				_file = file.open( File.join(@current_path, path) )
				mtime = _file.stat.mtime
				_file.close()
				return mtime
			end
    end
  end
end