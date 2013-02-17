require "yaml"
require "uri"
require "net/ftp"
require "net/sftp"
require "find"
require "fileutils"
require "colored"
require_relative "observer/sftp_compatibility.rb"

module Observer
  class Observer

		UP = ["up", "upload", "push"]
		DOWN = ["down", "download", "pull"]

		def initialize( ward )
			@debug = true

			# wd = working directory. Where the script has been called.
			@wd = prepPath( File.expand_path(".") )

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

			prepPath( @od )
			puts "Found Observer at #{@od}.observer.yml".green
			o = YAML.load_file(@od + ".observer.yml")

			@type = o["type"]

			puts "type => #{@type}".magenta if @debug

			@user = o["user"]
			@password = o["password"] || nil
			@ignore = o["ignore"]

			# Remove the leading "/" if necessary
			@server = clipRoot( o["server"] )

			@remote_path = prepPath( o["remote_path"] )

			# Default to the current directory
			# Ward is the target: a directory to watch or sync, or a file to sync
			@ward = !ward.nil? ? File.expand_path( ward ) : @wd
		end

		def debug( enabled )
			@debug = enabled
		end

		def self.spawn
			# sd = script directory. Where this file resides.
			sd = prepPath( File.expand_path(File.dirname(__FILE__)) )

			# wd = working directory. Where the script has been called.
			@wd = prepPath( File.expand_path(".") )

			# Observer prototype and new "instance"
			sdo = sd + "observer/observer.yml"
			wdo = @wd + ".observer.yml"

			if File.exist?( wdo )
				puts "An Observer already exists here, do you want to replace it? (y/n)".red
				if !yes?( STDIN.gets.chomp )
					puts "Exiting..."
					exit
				end
			end

			puts "Spawning observer...".blue
			FileUtils.cp( sdo, wdo )
			puts ".observer.yml".green + " was created for this directory." + " Please configure it for your server.".green
		end

		def transferFile( file, direction )
			params = Hash.new

			# Prepare filepaths
			params[:file] = File.expand_path(file)
			params[:r_filepath] = clipRoot( params[:file].sub( @od, @remote_path ) )
			params[:r_dirs] = params[:r_filepath].split(File::SEPARATOR)
			params[:r_file] = params[:r_dirs].pop()

			if @debug == true
				puts "file => #{params[:file]}"
				puts "remote_filepath => #{params[:r_filepath]}"
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

				begin
					ftp = Net::FTP.open( @server, @user, @password )
				rescue Net::FTPPermError
					puts "Login incorrect.".red
					exit
				else
					ftp.passive = true

					# Upload
					if UP.include? direction

						# Since FTP puts us in the server's root dir,
						# we need to look for the "public" or "www" dir:
						# ====================================================
						# This may need revising.
						# NOTE need to let it first try the supplied directory,
						# if not, try the following two:
						ftp.nlst().each do |dir|
							if ["public", "www"].include?(dir)
								ftp.chdir(dir)
								break
							end
						end

						upload( ftp, params )

					# Download
					elsif DOWN.include? direction
						download( ftp, params )

					end

					ftp.close()
				end

			# SFTP
			elsif @type.casecmp("sftp") == 0
				Net::SFTP.start( @server, @user, :password => @password ) do |sftp|

					# Upload
					if UP.include? direction
						upload( sftp, params )

					# Download
					elsif DOWN.include? direction
						download( sftp, params )

					end
				end

			else
				puts "Unrecognized protocol. Please use either 'ftp' or 'sftp'".red
				exit

			end
		end

		def transfer( item, direction )
			item = item || @ward

			# If it's a directory, we should load up everything
			if File.directory?(item)
				files = collectFiles( item )
				files.each do |file|
					transferFile( file[0], direction )
				end

			# Otherwise just sync
			else
				transferFile( item, direction )

			end
		end

		# Get rid of extra files and folders
		def prune( folder, direction )
			local_files = collectFiles( folder, true ).keys.map { |file| File.expand_path( file ) }
			remote_files = collectRemoteFiles( folder ).keys

			if UP.include?(direction)
				local_files.map! { |file| file.sub( @od, clipRoot(@remote_path) ) }
				diff = remote_files - local_files

				if @debug
					puts remote_files.inspect
					puts local_files.inspect
					puts diff.inspect
				end

				# TO DO do the remote deletes

			elsif DOWN.include?(direction)
				remote_files.map! { |file| file.sub( clipRoot(@remote_path), @od ) }
				diff = local_files - remote_files

				if @debug
					puts remote_files.inspect
					puts local_files.inspect
					puts diff.inspect
				end

				puts "The following files will be deleted:".red
				puts diff
				puts "Do you want to continue? (y/n)".red
				exit if !yes?( STDIN.gets.chomp )
				FileUtils.rm_r(diff)

			else
				puts "Unrecognized direction."
				exit
			end

			exit
		end

		# Push
		def push( item )
			#transfer( item, "push" )
			# temporary, for testing:
			prune( item, "pull" )
		end
		def syncUp( item )
			# transfer( item, "push" )
			if File.directory?(item)
				prune( item, "push" )
			end
		end
		def upload( ftp, params )
			r_filepath = params[:r_filepath]
			r_dirs = params[:r_dirs]
			r_file = params[:r_file]
			file = params[:file]

			puts "Uploading #{r_filepath}...".blue

			r_dirs.each do |dir|
				if !ftp.nlst().include?(dir)
					puts "Making #{dir}"
					ftp.mkdir(dir)
				end
				ftp.chdir(dir)
			end

			# Check for existing file
			# and compare modification time
			if ftp.nlst().include? r_file
				if ftp.mtime(r_file).to_i > File.stat(file).mtime.to_i
						puts "The file you are uploading is older than the one on the server. Do you want to overwrite the server file? (y/n)".red
						if !yes?( STDIN.gets.chomp )
							ftp.close()
							return
						end
				end
			end

			ftp.putbinaryfile(file, r_file)
			puts "Upload successful.".green
		end

		# Pull
		def pull( item )
			transfer( item, "pull" )
		end
		def syncDown( item )
			transfer( item, "pull" )
		end
		def download( ftp, params )
			r_filepath = params[:r_filepath]
			r_dirs = params[:r_dirs]
			r_file = params[:r_file]
			file = params[:file]

			puts "Downloading #{r_filepath}...".blue

			begin
				ftp.getbinaryfile(r_filepath, file)
			rescue
				# File doesn't exist
				puts "#{r_filepath} doesn't seem to exist!".red
				return
			end
		end

		# Observe
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
						transferFile( f, "push" )
					end
				end

				sleep 1
			end
		end

		private
		def connect

		end

		def collectFiles( folder, inc_folders = false )
			files = Hash.new
			Find.find( folder ) do |item|
				if @ignore.include?( File.basename(item) )
					Find.prune
					
				else
					next if !inc_folders && File.directory?(item)
					next if [".", "..", folder].include?(item)
					files[item] = File.stat(item).mtime.to_i
				end
			end
			return files
		end
		def collectRemoteFiles( folder )
			r_path = clipRoot( prepPath( File.expand_path( folder ) ).sub( @od, @remote_path ) )

			if @debug
				puts "@od => #{@od}"
				puts "@remote_path => #{@remote_path}"
				puts "r_path => #{r_path}"
			end

			# If the Observer's password is left unspecified,
			# ask for one
			if !@password
				puts "Password:"
				@password = STDIN.gets.chomp
			end

			#FTP
			if @type.casecmp("ftp") == 0
				begin
					ftp = Net::FTP.open( @server, @user, @password )
				rescue Net::FTPPermError
					puts "Login incorrect.".red
					exit
				else
					ftp.passive = true

					# Try to find proper dir
					ftp.nlst().each do |dir|
						if ["public", "www"].include?(dir)
							ftp.chdir(dir)
							break
						end
					end

					return remoteFind( ftp, r_path, {} )

				end
				ftp.close()

			# SFTP
			elsif @type.casecmp("sftp") == 0
				Net::SFTP.start( @server, @user, :password => @password ) do |sftp|
					return remoteFind( sftp, r_path, {} )
				end

			else
				puts "Unrecognized protocol. Please use either 'ftp' or 'sftp'".red
				exit

			end
		end

		# A remote version of File.find
		def remoteFind( ftp, path, hash )
			puts "current path => #{path}" if @debug

			ftp.nlst(path).each do |item|
				next if [".", "..", File.join(path, "."), File.join(path, "..")].include?(item)
				next if @ignore.include?( File.basename(item) )
				item = File.join(path, item) if !item.include?(path)

				puts "current item => #{item}" if @debug

				# Net::FTP will throw an FTPPermError
				# if trying to mtime a directory.
				begin
					hash[item] = ftp.mtime(item).to_i
				rescue Net::FTPPermError
					hash[item] = "n/a"
				end

				# So far I have not been able to find
				# any reliable equivalent of File.directory?
				# for remote files.
				# However, there's a heuristic we can use.
				# ftp.nlst(item).length > 1 means it's a directory,
				# since it will include at the very least "item/."
				# and "item/.." (i.e. have a length of 2). If it's
				# a file, only the file itself will be included.
				if ftp.nlst(item).length > 1
					puts "#{item} is a directory".red if @debug
					remoteFind( ftp, item, hash )
				end
			end
			puts "finished #{path}".blue if @debug
			return hash
		end

		# Most paths need to have a trailing "/"
		# Add it if necessary
		def self.prepPath( path )
			path << "/" if path[-1] != "/"
			return path
		end
		def prepPath( path )
			return self.class.prepPath( path )
		end
		def clipRoot( path )
			clipped_path = path[0] == "/" ? path[1..-1] : path
			return clipped_path
		end

		def yes?( response )
			return ["y", "yes", "yeah", "yea"].include?(response.downcase)
		end

	end
end
