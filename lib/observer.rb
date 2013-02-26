require "yaml"
require "uri"
require "net/ftp"
require "net/sftp"
require "find"
require "fileutils"
require "colored"
require File.join(File.dirname(__FILE__), 'observer/sftp_compatibility.rb')

module Observer
  class Observer

		UP = ["up", "upload", "push"]
		DOWN = ["down", "download", "pull"]
		YES = ["y", "yes", "yeah", "yea"]

		def initialize( ward )
			# wd = working directory. Where the script has been called.
			@wd = prepPath( File.expand_path(".") )

			# od = Observer directory. Where the Observer resides
			# Search up to find an Observer
			@od = @wd
			while !File.exists?(@od + "/.observer") do
				@od = File.expand_path( File.join(@od, "..") )

				if ( @od == "/" )
					puts "A .observer couldn't be found.".red
					puts "Create one with " + "'observer spawn'".blue
					exit
				end
			end

			prepPath( @od )
			puts "Found Observer at #{@od}.observer".magenta
			o = YAML.load_file(@od + ".observer")

			@type = o["type"]
			@user = o["user"]
			@password = o["password"] || nil
			@ignore = o["ignore"]
			@connection = nil
			@server = clipRoot( o["server"] )
			@remote_path = prepPath( o["remote_path"] )

			# Default to the current directory
			# Ward is the target: a directory to watch or sync, or a file to sync
			@ward = !ward.nil? ? File.expand_path( ward ) : @wd
		end

		def self.spawn
			# sd = script directory. Where this file resides.
			sd = prepPath( File.expand_path(File.dirname(__FILE__)) )

			# wd = working directory. Where the script has been called.
			@wd = prepPath( File.expand_path(".") )

			# Observer prototype and new "instance"
			sdo = sd + "observer/observer.yml"
			wdo = @wd + ".observer"

			if File.exist?( wdo )
				puts "An Observer already exists here, do you want to replace it? (y/n)".red
				if !yes?( STDIN.gets.chomp )
					puts "Exiting..."
					exit
				end
			end

			puts "Spawning observer...".blue
			FileUtils.cp( sdo, wdo )
			puts "A .observer".green + " was created for this directory." + " Please configure it for your server.".green

			# Try to add the Observer to the gitignore
			gitignore = File.join(@wd, ".gitignore")
			if File.exist?( gitignore )
				open(gitignore, 'a') do |f|
				  f << "\n.observer"
				end
				puts "Your gitignore was modified to include '.observer.'"
			else
				puts "A gitignore file could not be found. "\
						 "It's recommended to keep your .observer "\
						 "out of versioning since it may contain sensitive information.".red
			end
		end

		# Push
		def push( item, force=false )
			transfer( item, "push", force )
		end

		# Sync remote with local (i.e. make remote match local)
		# Will delete items not present on local
		def syncUp( item, force=false )
			transfer( item, "push", force )
			if File.directory?(item)
				prune( item, "push", force )
			end
		end

		# Pull
		def pull( item, force=false )
			transfer( item, "pull", force )
		end

		# Sync local with remote (i.e. make local match remote)
		# Will delete items not present on remote
		def syncDown( item, force=false )
			transfer( item, "pull", force )
			if File.directory?(item)
				prune( item, "pull", force )
			end
		end

		# Observe
		def observe
			puts "Observing #{@ward} for changes...".blue

			# Props to rjfranco (https://github.com/rjfranco)
			# for the basis of this code:
			while true do
				new_files = collectLocalFiles( @ward )

				# Compare
				files ||= new_files
				diff = new_files.to_a - files.to_a

				unless diff.empty?
					files = new_files
					diff.each do |f|
						puts f[0].red + " was changed. Syncing..."
						transferFile( f, "push" )
					end
				end

				sleep 1
			end
		end

		private
		def connect
			if !@password
				puts "Password:"
				@password = STDIN.gets.chomp
			end

			puts "Connecting to #{@server}...".blue

			#FTP
			if @type.casecmp("ftp") == 0
				begin
					ftp = Net::FTP.open( @server, @user, @password )
				rescue Net::FTPPermError
					puts "Login incorrect.".red
					exit
				end

				ftp.passive = true

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

				@connection = ftp

			# SFTP
			elsif @type.casecmp("sftp") == 0
				sftp = Net::SFTP.start( @server, @user, :password => @password )
				@connection = sftp

			else
				puts "Unrecognized protocol. Please use either 'ftp' or 'sftp'".red
				exit

			end
		end

		def close
			@connection.close
			puts "Disconnecting from #{@server}...".blue
		end

		def transfer( item, direction, force )
			item = item || @ward

			# If it's a directory, we should load up everything
			if File.directory?(item)
				files = collectLocalFiles( item )
				files.each do |file|
					transferFile( file[0], direction, force )
				end

			# Otherwise just sync
			else
				transferFile( item, direction, force )

			end
		end
		def transferFile( file, direction, force=false )
			connect unless @connection
			params = Hash.new

			# Prepare filepaths
			passed_file = File.expand_path(file)
			params[:r_file] = clipRoot( passed_file.sub( @od, @remote_path ) )
			params[:l_file] = passed_file.sub( @remote_path, @od )
			params[:r_dirs] = params[:r_file].split(File::SEPARATOR)[0...-1]
			params[:l_dirs] = params[:l_file].split(File::SEPARATOR)[1...-1]

			if UP.include? direction
				upload( params, force )
			elsif DOWN.include? direction
				download( params, force )
			else
				puts "Unrecognized direction."
				close
				exit
			end
		end

		# Upload a file
		def upload( params, force )
			connect unless @connection
			c = @connection
			r_file = params[:r_file]
			r_dirs = params[:r_dirs]
			l_file = params[:l_file]

			puts "Uploading #{r_file}...".blue

			# Create remote dirs as necessary
			prev_dir = ""
			r_dirs.each do |dir|
				dirpath = clipRoot( File.join(prev_dir, dir) )
				# This long thing is to introduce consistency
				# in how Net::FTP and Net::SFTP return their listings
				if !c.nlst(prev_dir).map { |item| item.split(File::SEPARATOR).last }.include?(dir)
					puts "Making #{dirpath}"
					c.mkdir(dirpath)
				end
				prev_dir = dirpath
			end

			# Check for existing remote file
			# and compare modification time
			if c.nlst(prev_dir).include?(File.basename(r_file)) && !force
				if c.mtime(r_file).to_i > File.stat(l_file).mtime.to_i
						puts "The file you are uploading is older than the one on the server. "\
								 "Do you want to overwrite the remote file? (y/n)".red
						if !yes?( STDIN.gets.chomp )
							close
							return
						end
				end
			end

			c.putbinaryfile(l_file, r_file)
			puts "Upload successful.".green
		end

		# Download a file
		def download( params, force )
			connect unless @connection
			c = @connection
			l_file = params[:l_file]
			l_dirs = params[:l_dirs]
			r_file = params[:r_file]

			puts "Downloading #{r_file}...".blue

			# Create local dirs as necessary
			prev_dir = "/"
			l_dirs.each do |dir|
				dirpath = File.join(prev_dir, dir)
				if !Dir.entries(prev_dir).include?(dir)
					puts "Making #{dirpath}"
					Dir.mkdir(dirpath)
				end
				prev_dir = dirpath
			end

			# Check for existing local file
			# and compare modification time
			if Dir.entries(prev_dir).include?(File.basename(l_file)) && !force
				if c.mtime(r_file).to_i < File.stat(l_file).mtime.to_i
						puts "The file you are downloading is older than the one on your machine. "\
								 "Do you want to overwrite the local file? (y/n)".red
						if !yes?( STDIN.gets.chomp )
							close
							return
						end
				end
			end

			begin
				c.getbinaryfile(r_file, l_file)
			rescue
				# File doesn't exist
				puts "#{r_file} doesn't seem to exist!".red
				return
			end
		end

		# Get rid of extra files and folders
		def prune( folder, direction, force )
			connect unless @connection
			c = @connection

			l_files = collectLocalFiles( folder, true ).keys.map { |file| File.expand_path( file ) }
			r_files = collectRemoteFiles( folder ).keys

			if UP.include?(direction)
				l_files.map! { |file| file.sub( @od, clipRoot(@remote_path) ) }
				diff = r_files - l_files

				diff.reverse.each do |item|
					# Is directory
					if c.nlst(item).length > 1
						c.rmdir(item)

					# Is a file
					else
						c.delete(item)
					end
				end


			elsif DOWN.include?(direction)
				r_files.map! { |file| file.sub( clipRoot(@remote_path), @od ) }
				diff = l_files - r_files

				if diff.length > 0 && !force
					puts "The following files will be deleted:".red
					puts diff
					puts "Do you want to continue? (y/n)".red
					exit if !yes?( STDIN.gets.chomp )
				end

				# We remove things in reverse 
				# so that we avoid removing a parent dir
				# before removing it's child elements.
				FileUtils.rm_r(diff.reverse)

			else
				puts "Unrecognized direction."
				close
				exit
			end
		end

		def collectLocalFiles( folder, inc_folders = false )
			files = Hash.new
			Find.find( folder ) do |item|
				if @ignore.include?( File.basename(item) )
					Find.prune
					
				else
					# Skip if we're not including folders & this is a folder
					next if !inc_folders && File.directory?(item)

					# To prevent looping & redundancy
					next if [".", "..", folder].include?(item)

					files[item] = File.stat(item).mtime.to_i
				end
			end
			return files
		end
		def collectRemoteFiles( folder )
			r_path = clipRoot( prepPath( File.expand_path( folder ) ).sub( @od, @remote_path ) )
			return remoteFind( r_path, {} )
		end

		# A remote version of File.find
		def remoteFind( path, hash )
			connect unless @connection
			c = @connection

			c.nlst(path).each do |item|
				next if @ignore.include?( File.basename(item) )

				# To prevent looping & redundancy
				next if [".", "..", File.join(path, "."), File.join(path, "..")].include?(item)
				item = File.join(path, item) if !item.include?(path)

				# Net::FTP will throw an FTPPermError
				# if trying to mtime a directory.
				begin
					hash[item] = c.mtime(item).to_i
				rescue Net::FTPPermError
					hash[item] = "n/a"
				end

				# So far I have not been able to find
				# any reliable equivalent of File.directory?
				# for remote files.
				# However, there's a heuristic we can use.
				# c.nlst(item).length > 1 means it's a directory,
				# since it will include at the very least "item/."
				# and "item/.." (i.e. have a length of 2). If it's
				# a file, only the file itself will be included.
				if c.nlst(item).length > 1
					remoteFind( item, hash )
				end
			end
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
			return YES.include?(response.downcase)
		end

	end
end
