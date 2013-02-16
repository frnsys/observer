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

		PUSH = ["up", "upload", "push"]
		PULL = ["down", "download", "pull"]

		def initialize( ward )
			@debug = true

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

		def syncFile( file, direction )
			params = Hash.new

			# Prepare filepaths
			params[:file] = File.expand_path(file)
			r_filepath = params[:file].sub( @od, @remote_path )

			# A leading slash will mess things up.
			# Get rid of it if it's there
			params[:r_filepath] = r_filepath[0] == "/" ? r_filepath[1..-1] : r_filepath
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
					if PUSH.include? direction

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
					elsif PULL.include? direction
						download( ftp, params )

					end

					ftp.close()
				end

			# SFTP
			elsif @type.casecmp("sftp") == 0
				Net::SFTP.start( @server, @user, :password => @password ) do |sftp|

					# Upload
					if PUSH.include? direction
						upload( sftp, params )

					# Download
					elsif PULL.include? direction
						download( sftp, params )

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

		# Push
		def push( item )
			sync( item, "push" )
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
			sync( item, "pull" )
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
			return ["y", "yes", "yeah", "yea"].include?(response.downcase)
		end

	end
end
