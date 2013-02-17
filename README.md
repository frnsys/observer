# Observer
### Developed by Francis Tseng ([supermedes.com](http://www.supermedes.com) / @frnsys)

A command line tool that will watch a directory for changes & sync it to a remote directory (ftp or sftp)
 
## Installation
```
$ gem install observer
```

## Usage
Setup an Observer:
```
$ observer spawn
```
This will create a `.observer` in your current directory. You will need to configure this file with your server settings.

Watch the current directory:
```
$ observer observe
```

Watch a directory:
```
$ observer observe /path/to/local/dir
```

Upload a single file or directory:
```
$ observer push /path/to/local/dir
```

Download a single file or directory:
```
$ observer pull /path/to/remote/dir
```

Sync a remote directory to a local directory:
```
$ observer syncup /path/to/local/dir
```

Sync a local directory to a remote directory:
```
$ observer syncdown /path/to/remote/dir
```

## Contributing
This is still a work in progress and can use improving, so please contribute!