require "yaml"
require "uri"
require "net/ftp"
require "net/sftp"
require "find"
require "fileutils"
require "observer/version"
require "colored"

module Observer
  class Observer

		def initialize( ward )
			# wd = working directory. Where the script has been called.
			@wd = sanitizePath( File.expand_path(".") )

			# od = Observer directory. Where the Observer resides
			@od = @wd
			while !File.exists?(@od + "/.observer.yml") do
				@od = File.expand_path( File.join(@od, "..") )

				if ( @od == "/" )
					puts ".observer.yml couldn't be found.".red
					puts "Create one with " + "'observer spawn'".blue
				exit
				end
			end

			sanitizePath( @od )
			puts "Found Observer at #{@od}.observer.yml".green
			o = YAML.load_file(@od + ".observer.yml")

			@type = o["type"]
			@user = o["user"]
			@password = o["password"] || nil
			@ignore = o["ignore"]

			# Remove the leading "/" if necessary
			@server = o["server"]
			@server = @server[1..-1] if @server[0] == "/"

			@remote_path = sanitizePath( o["remote_path"] )

			# Default to the current directory
			# Ward is the target: a directory to watch or sync, or a file to sync
			@ward = !ward.nil? ? File.expand_path( ward ) : @wd
		end

		def debug( enabled )
			@debug = enabled
		end

		def self.spawn
			# sd = script directory. Where this file resides.
			sd = sanitizePath( File.expand_path(File.dirname(__FILE__)) )
			# wd = working directory. Where the script has been called.
			@wd = sanitizePath( File.expand_path(".") )
			sdo = sd + "observer/observer.yml"
			wdo = @wd + ".observer.yml"

			if File.exist?( wdo )
				puts "An Observer already exists here, do you want to replace it? (y/n)".red
				response = STDIN.gets.chomp
				if yes?( response )
					puts "Exiting..."
					exit
				end
			end

			puts "Spawning observer...".blue
			FileUtils.cp( sdo, wdo )
		end

		def syncFile( file, direction )
			# Prepare filepaths
			file = File.expand_path(file)
			remote_file = file.sub( @od, @remote_path )
			# A leading slash will mess things up.
			# Get rid of it if it's there
			remote_file = remote_file[0] == "/" ? remote_file[1..-1] : remote_file

			if @debug = true
				puts "file => #{file}"
				puts "remote_file => #{remote_file}"
				puts "@od => #{@od}"
				puts "@remote_path => #{@remote_path}"
			end

			# If the Observer's password is left unspecified,
			# ask for one
			if !@password
				puts "Password:"
				@password = STDIN.gets.chomp
			end

			puts "Connecting to #{@server}...".blue

			# FTP
			if @type.casecmp("ftp") == 0
				ftp = Net::FTP.open( @server, @user, @password )
				ftp.passive = true
				puts "Syncing #{file} to " + remote_file.blue
				ftp.putbinaryfile(file, remote_file)
				ftp.close
				puts "Upload successful.".green

			# SFTP
			elsif @type.casecmp("sftp") == 0
				Net::SFTP.start( @server, @user, :password => @password ) do |sftp|

					# Upload
					if ["upload", "up", "push"].include? direction
						puts "Uploading #{remote_file}...".blue

						# Check if the file already exists
						begin
							existing_file = sftp.file.open(remote_file)

							# Warn user that they're overwriting a newer file
							if File.stat(file).mtime.to_i < existing_file.stat.mtime
								puts "The file you are uploading is older than the one on the server. Do you want to overwrite the server file? (y/n)".red
								response = STDIN.gets.chomp
								if yes?( response )
									existing_file.close()
									return
								end
							end
							existing_file.close()
						rescue
							# File doesn't exist
						end

						# Try the upload
						begin
							sftp.upload!( file, remote_file )
							success = true

						# If it doesn't work,
						# there are probably missing subdirs
						# net-sftp will throw this error:
						rescue Net::SFTP::StatusException
							# Keep track of the dir we need to create
							dirs = Array.new
							dirs << File.dirname(remote_file)

							while true do
								begin
									# Check if each parent dir exists
									parent_dir = dirs.last[0] == "/" ? dirs.last[1..-1] : dirs.last
									puts "parent_dir => #{parent_dir}" if @debug == true
									sftp.open!( parent_drr )

								rescue Net::SFTP::StatusException
									# If it doesn't exist, keep track
									dirs << File.expand_path( File.join( dirs.last, ".." ) ).sub( @wd, "")
									
								else
									# Found a dir that exists!
									# The last dir will be the first dir that already exists.
									# So we remove it.
									dirs.pop

									# Now create the directories
									dirs.reverse_each do |dir|
										puts "Making #{dir}"
										sftp.mkdir!(dir) 
									end
									break
								end
							end

							# If it failed, try uploading the file again
							sftp.upload!( file, remote_file ) if !success

						end

					# Download
					elsif ["download", "down", "pull"].include? direction
						
						# Check if the file already exists
						if File.exists?(file)
							begin
								existing_file = sftp.file.open(remote_file)

								# Warn user that they're overwriting a newer file
								if File.stat(file).mtime.to_i > existing_file.stat.mtime
									puts "The file you are downloading is older than the local copy. Do you want to overwrite the local file? (y/n)".red
									response = STDIN.gets.chomp
									if yes?( response )
										existing_file.close()
										return
									end
								end
								existing_file.close()
							rescue
								# File doesn't exist
								puts "#{remote_file} doesn't seem to exist!".red
								return
							end
						end

						# Try the download
						begin
							sftp.download!( remote_file, file )

						rescue Net::SFTP::StatusException
							puts "#{remote_file} doesn't seem to exist!".red
							return

						else
							puts "Downloaded #{remote_file}".blue

						end

					end
				end

			else
				puts "Unrecognized protocol type. Please use either 'ftp' or 'sftp'".red
				exit
			end
		end
		
		def sync( item, direction )
			item = item || @ward

			# If it's a directory, we should load up everything
			if File.directory?(item)
				files = collectFiles( item )
				files.each do |file|
					syncFile( file[0], direction )
				end

			# Otherwise just sync
			else
				syncFile( item, direction )

			end
		end
		def push( item )
			sync( item , "push" )
		end
		def pull( item )
			sync( item, "pull" )
		end

		def observe
			puts "Observing #{@ward} for changes...".blue

			# Props to rjfranco (https://github.com/rjfranco)
			# for the basis of this code:
			while true do
				newfiles = collectFiles( @ward )

				# Compare
				files ||= newfiles
				dfiles = newfiles.to_a - files.to_a

				unless dfiles.empty?
					files = newfiles
					dfiles.each do |f|
						puts f[0].red + " was changed. Syncing..."
						syncFile( f, "push" )
					end
				end

				sleep 1
			end
		end

		private
		def collectFiles( folder )
				files = Hash.new
				Find.find( folder ) do |path|
					if @ignore.include?( File.basename(path) )
						Find.prune
						
					else
						# We only want to include files, not folders
						if !File.directory?(path)
							files[path] = File.stat(path).mtime.to_i
						end
					end
				end
				return files
		end

		# Most paths need to have a trailing "/"
		# Add it if necessary
		def self.sanitizePath( path )
			path << "/" if path[-1] != "/"
			return path
		end
		def sanitizePath( path )
			return self.class.sanitizePath( path )
		end

		def yes?( response )
			return !["y", "yes", "yeah", "yea"].include?(response.downcase)
		end

	end
end
