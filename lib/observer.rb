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
			@user = o["user"]
			@password = o["password"] || nil
			@ignore = o["ignore"]

			# Remove the leading "/" if necessary
			@server = o["server"]
			@server = @server[1..-1] if @server[0] == "/"

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

		def prune( folder, direction )
			# Collect files starting at node "item"
			# Both locally and remotely
			files = collectRemoteFiles( folder )
		end

		# Push
		def push( item )
			#transfer( item, "push" )
			# temporary, for testing:
			prune( item, "push" )
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
		def collectFiles( folder )
			files = Hash.new
			Find.find( folder ) do |item|
				if @ignore.include?( File.basename(item) )
					Find.prune
					
				else
					# We only want to include files, not folders
					if !File.directory?(item)
						files[item] = File.stat(item).mtime.to_i
					end
				end
			end
			return files
		end
		def collectRemoteFiles( folder )
			r_files = Hash.new
			r_path = prepPath( File.expand_path( folder ) ).sub( @od, @remote_path )
			r_path = r_path[0] == "/" ? r_path[1..-1] : r_path

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

				end
				ftp.close()

			elsif @type.casecmp("sftp") == 0
				Net::SFTP.start( @server, @user, :password => @password ) do |sftp|
					files = Hash.new
					puts remoteFind( sftp, r_path, files )
				end

			else
				puts "Unrecognized protocol. Please use either 'ftp' or 'sftp'".red
				exit

			end
		end

		# A remote version of File.find
		def remoteFind( ftp, folder, hash )
			puts "current folder => #{folder}" if @debug

			ftp.chdir( folder )
			ftp.nlst().each do |item|
				if @ignore.include?( File.basename(item) )
					puts "ignoring #{item}" if @debug
					next
				else
					if [".", ".."].include?(item)
						next
					end
					puts "current item => #{item}" if @debug

					hash[item] = ftp.mtime(item).to_i
					if File.directory?(item)
						remoteFind( ftp, item, hash )
					end
				end
			end
			puts "finished #{folder}".blue if @debug
			ftp.chdir("..")
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

		def yes?( response )
			return ["y", "yes", "yeah", "yea"].include?(response.downcase)
		end

	end
end
