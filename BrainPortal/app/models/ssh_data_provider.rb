
#
# CBRAIN Project
#
# $Id$
#

require 'rubygems'
require 'net/ssh'
require 'net/sftp'

#
# This class provides an implementation for a data provider
# where the remote files are accessed through +ssh+ and +rsync+.
# The provider's files are stored in a flat directory, one
# level deep, directly specified by the object's +remote_dir+
# attribute. The file "hello" is thus stored in a path like this:
#
#     /remote_dir/hello
#
# For the list of API methods, see the DataProvider superclass.
#
class SshDataProvider < DataProvider

  Revision_info="$Id$"

  def impl_is_alive? #:nodoc:
    ssh_opts = self.ssh_shared_options
    ssh_opts.sub!(/ConnectTimeout=\d+/,"ConnectTimeout=1")
    dir  = shell_escape(self.remote_dir)
    text = bash_this("ssh -x -n #{ssh_opts} test -d #{dir} '||' echo Fail-Dir 2>&1")
    return(text.blank? ? true : false);
  rescue
    false
  end

  # Please make sure that subclasses that are not
  # browsable resets this value to false.
  def is_browsable? #:nodoc:
    true
  end

  def impl_sync_to_cache(userfile) #:nodoc:
    localfull   = cache_full_path(userfile)
    remotefull  = remote_full_path(userfile)
    sourceslash = ""

    mkdir_cache_subdirs(userfile)
    if userfile.is_a?(FileCollection)
      Dir.mkdir(localfull) unless File.directory?(localfull)
      sourceslash="/"
    end

    rsync = rsync_over_ssh_prefix
    text = bash_this("#{rsync} -a -l --delete :#{shell_escape(remotefull)}#{sourceslash} #{shell_escape(localfull)} 2>&1")
    text.sub!(/Warning: Permanently added[^\n]+known hosts.\s*/i,"")
    cb_error "Error syncing userfile to local cache: rsync returned: #{text}" unless text.blank?
    true
  end

  def impl_sync_to_provider(userfile) #:nodoc:
    localfull   = cache_full_path(userfile)
    remotefull  = remote_full_path(userfile)
    cb_error "Error: file #{localfull} does not exist in local cache!" unless File.exist?(localfull)

    sourceslash = userfile.is_a?(FileCollection) ? "/" : ""
    rsync = rsync_over_ssh_prefix
    text = bash_this("#{rsync} -a -l --delete #{shell_escape(localfull)}#{sourceslash} :#{shell_escape(remotefull)} 2>&1")
    text.sub!(/Warning: Permanently added[^\n]+known hosts.\s*/i,"")
    cb_error "Error syncing userfile to data provider: rsync returned: #{text}" unless text.blank?
    true
  end

  def impl_provider_erase(userfile) #:nodoc:
    full     = remote_full_path(userfile)
    ssh_opts = self.ssh_shared_options
    bash_this("ssh -x -n #{ssh_opts} \"bash -c '/bin/rm -rf #{full} >/dev/null 2>&1'\"")
    true
  end

  def impl_provider_rename(userfile,newname) #:nodoc:
    oldpath   = remote_full_path(userfile)
    remotedir = oldpath.parent
    newpath   = remotedir + newname

    oldpath   = oldpath.to_s
    newpath   = newpath.to_s

    Net::SFTP.start(remote_host,remote_user, :port => remote_port, :auth_methods => 'publickey') do |sftp|
      begin
        att = sftp.lstat!(newpath)
        return false # means file exists already
      end rescue
      begin
        sftp.rename!(oldpath,newpath)
        userfile.name = newname
        return true
      rescue
        return false
      end
    end
    false
  end

  def impl_provider_list_all #:nodoc:
    list = []
    Net::SFTP.start(remote_host,remote_user, :port => remote_port, :auth_methods => 'publickey') do |sftp|
      sftp.dir.foreach(remote_dir) do |entry|
        attributes = entry.attributes
        type = attributes.symbolic_type
        next if type != :regular && type != :directory && type != :symlink
        next if entry.name == "." || entry.name == ".."

        fileinfo               = FileInfo.new
        fileinfo.name          = entry.name

        attlist = [ 'symbolic_type', 'size', 'permissions',
                    'uid',  'gid',  'owner', 'group',
                    'atime', 'ctime', 'mtime' ]
        attlist.each do |meth|
          # if attributes.respond_to?(meth) && fileinfo.respond_to?("#{meth}=") 
          #   val = attributes.send(meth)
          #   fileinfo.send("#{meth}=", val)
          # end
          begin
            val = attributes.send(meth)
            fileinfo.send("#{meth}=", val)
          rescue => e
            puts "Method #{meth} not supported: #{e.message}"
          end
        end

        list << fileinfo
      end
    end
    list.sort! { |a,b| a.name <=> b.name }
    list
  end
  
  def impl_provider_collection_index(userfile, directory = :all, allowed_types = :regular) #:nodoc:
    list = []
    
    if allowed_types.is_a? Array
      types = allowed_types.dup
    else
      types = [allowed_types]
    end
      
    types.map!(&:to_sym)
    
    
    Net::SFTP.start(remote_host,remote_user, :port => remote_port, :auth_methods => 'publickey') do |sftp|
       if userfile.is_a? FileCollection
         if directory == :all
           entries = sftp.dir.glob(remote_full_path(userfile).parent.to_s, userfile.name + "/**/*")
         else
           base_dir = "/" + directory + "/"
           base_dir.gsub!(/\/+/, "/")
           base_dir.gsub!(/\/\.\//, "/")
           entries = sftp.dir.entries(remote_full_path(userfile).to_s + base_dir ).reject{ |e| e.name =~ /^\./}.inject([]) { |result, e| result << e }
         end
       else
         entries = sftp.dir.entries(remote_full_path(userfile).parent.to_s).select{ |e| e.name == userfile.name}
       end
       entries.each do |entry|
        attributes = entry.attributes
        type = attributes.symbolic_type
        next unless types.include?(type)
        #next if entry.name == "." || entry.name == ".."

        fileinfo               = FileInfo.new
        if entry.name =~ /^#{userfile.name}/
          fileinfo.name          = entry.name
        else
          fileinfo.name          = "#{userfile.name}#{base_dir}#{entry.name}"
        end 
        attlist = [ 'symbolic_type', 'size', 'permissions',
                    'uid',  'gid',  'owner', 'group',
                    'atime', 'ctime', 'mtime' ]
        attlist.each do |meth|
          # if attributes.respond_to?(meth) && fileinfo.respond_to?("#{meth}=") 
          #   val = attributes.send(meth)
          #   fileinfo.send("#{meth}=", val)
          # end
          begin
            val = attributes.send(meth)
            fileinfo.send("#{meth}=", val)
          rescue => e
            puts "Method #{meth} not supported: #{e.message}"
          end
        end

        list << fileinfo
      end
    end
    list.sort! { |a,b| a.name <=> b.name }
    list
  end

  # Returns the full path to the content of +userfile+ on
  # the data provider's side. This is to be overriden
  # by subclasses where files are stored differently
  # on the provider's side.
  def remote_full_path(userfile)
    basename = userfile.name
    Pathname.new(remote_dir) + basename
  end
  
  protected

  # Builds a prefix for a +rsync+ command, such as
  #
  #   "rsync -e 'ssh -x -o a=b -o c=d -p port user@host'"
  #
  # Note that this means that remote file specifications for
  # rsync MUST start with a bare ":" :
  #
  #   rsync -e 'ssh_options_here user_host'  :/remote/file  local/file
  def rsync_over_ssh_prefix
    ssh_opts = self.ssh_shared_options
    ssh      = "ssh -x #{ssh_opts}"
    rsync    = "rsync -e #{shell_escape(ssh)}"
    rsync
  end

  # Returns the necessary options to connect to a master SSH
  # command running in the background (which will be started if
  # necessary).
  def ssh_shared_options
    @master ||= SshTunnel.find_or_create(remote_user,remote_host,remote_port)
    @master.start("DataProvider_#{self.name}") # does nothing is it's already started
    @master.ssh_shared_options("auto") # ControlMaster=auto
  end
  
  #################################################################
  # Shell utility methods
  #################################################################

  # This utility method escapes properly any string such that
  # it becomes a literal in a bash command; the string returned
  # will include the surrounding single quotes.
  #
  #   shell_escape("Mike O'Connor")
  #
  # returns
  #
  #   'Mike O'\''Connor'
  def shell_escape(s)
    "'" + s.to_s.gsub(/'/,"'\\\\''") + "'"
  end

  # This utility method runs a bash command, intercepts the output
  # and returns it.
  def bash_this(command)
    #puts "BASH: #{command}"
    fh = IO.popen(command,"r")
    output = fh.read
    fh.close
    output
  end

end

