require 'open-uri'
require 'project'

module Webui
class PackageController < WebuiController

  include HasComments
  include ParsePackageDiff
  include WebuiHelper
  include PackageHelper
  include Escaper

  before_filter :require_project, :except => [:rawlog, :rawsourcefile, :submit_request, :devel_project]
  before_filter :require_package, :except => [:rawlog, :rawsourcefile, :submit_request, :save_new_link, :save_new, :devel_project ]
  # make sure it's after the require_, it requires both
  before_filter :require_login, :only => [:branch]
  prepend_before_filter :lockout_spiders, :only => [:revisions, :dependency, :rdiff, :binary, :binaries, :requests]

  def show
    if lockout_spiders
      params.delete(:rev)
      params.delete(:srcmd5)
    end

    @srcmd5   = params[:srcmd5]
    @revision_parameter = params[:rev]

    begin
      @buildresult = Buildresult.find_hashed(:project => @project, :package => @package, :view => 'status' ) unless @spider_bot
    rescue => e
      logger.error "No buildresult found for #{@project} / #{@package} : #{e.message}"
    end
    @bugowners_mail = []
    (@package.bugowners + @project.bugowners).uniq.each do |bugowner|
        mail = bugowner.email if bugowner
        @bugowners_mail.push(mail.to_s) if mail
    end unless @spider_bot
    @revision = params[:rev]
    @failures = 0
    fill_status_cache unless @buildresult.blank?
    set_linking_packages
    @expand = 1
    @expand = begin Integer(params[:expand]) rescue 1 end if params[:expand]
    @expand = 0 if @spider_bot
    @is_current_rev = false
    if set_file_details
      if @forced_unexpand.blank?
        @is_current_rev = !@revision || (@revision == @current_rev)
      else
        flash[:error] = "Files could not be expanded: #{@forced_unexpand}"
      end
    elsif @revision_parameter
      flash[:error] = "No such revision: #{@revision_parameter}"
      redirect_back_or_to :controller => 'package', :action => 'show', :project => @project, :package => @package and return
    end

    sort_comments(@package.api_obj.comments)

    @requests = []
    # TODO!!!
    #BsRequest.list({:states => %w(review), :reviewstates => %w(new), :roles => %w(reviewer), :project => @project.name, :package => @package.name}) +
    #BsRequest.list({:states => %w(new), :roles => %w(target), :project => @project.name, :package => @package.name})
  end

  def comment_object
    @package # used by HasComments mixin
  end

  def files
    # we need to keep this as long as it's in google's index
    redirect_to url_for(action: :show, package: params[:package], project: params[:project]), :status => :moved_permanently
  end

  def set_linking_packages
    @linking_packages = @package.api_obj.linking_packages
  end

  def linking_packages
    set_linking_packages
    render_dialog
  end

  def dependency
    @arch = params[:arch]
    @repository = params[:repository]
    @drepository = params[:drepository]
    @dproject = params[:dproject]
    @filename = params[:filename]
    @fileinfo = Fileinfo.find(:project => params[:dproject], :package => '_repository', :repository => params[:drepository], :arch => @arch,
      :filename => params[:dname], :view => 'fileinfo_ext')
    @durl = nil
    unless @fileinfo # avoid displaying an error for non-existing packages
      redirect_back_or_to(:action => 'binary', :project => params[:project], :package => params[:package], :repository => @repository, :arch => @arch, :filename => @filename)
    end
  end

  def statistics
    required_parameters :arch, :repository
    @arch = params[:arch]
    @repository = params[:repository]
    @statistics = nil
    begin
      @statistics = Statistic.find( project: @project, package: @package, repository: @repository, arch: @arch )
      @statistics = @statistics.to_hash if @statistics
    rescue ActiveXML::Transport::ForbiddenError
    end
    logger.debug "Statis #{@statistics.inspect}"
    unless @statistics
      flash[:error] = "No statistics of a successful build could be found in #{@repository}/#{@arch}"
      redirect_to controller: 'package', action: :binaries, project: @project,
        package: @package, repository: @repository, nextstatus: 404
      return
    end
  end

  def binary
    required_parameters :arch, :repository, :filename
    @arch = params[:arch]
    @repository = params[:repository]
    @filename = params[:filename]
    begin
      @fileinfo = Fileinfo.find(:project => @project, :package => @package, :repository => @repository, :arch => @arch,
        :filename => @filename, :view => 'fileinfo_ext')
    rescue ActiveXML::Transport::ForbiddenError => e
      flash[:error] = "File #{@filename} can not be downloaded from #{@project}: #{e.summary}"
    end
    unless @fileinfo
      flash[:error] = "File \"#{@filename}\" could not be found in #{@repository}/#{@arch}"
      redirect_to :controller => 'package', :action => :binaries, :project => @project,
        :package => @package, :repository => @repository, :nextstatus => 404
      return
    end
    @durl = "#{repo_url( @project, @repository )}/#{@fileinfo.arch}/#{@filename}" if @fileinfo.value :arch
    @durl = "#{repo_url( @project, @repository )}/iso/#{@filename}" if (@fileinfo.value :filename) =~ /\.iso$/
    if @durl and not file_available?( @durl )
      # ignore files not available
      @durl = nil
    end
    unless User.current.is_nobody? or @durl
      # only use API for logged in users if the mirror is not available
      @durl = rpm_url( @project, @package, @repository, @arch, @filename )
    end
    logger.debug "accepting #{request.accepts.join(',')} format:#{request.format}"
    # little trick to give users eager to download binaries a single click
    if request.format != Mime::HTML and @durl
      redirect_to @durl
      return
    end
  end

  def binaries
    required_parameters :repository
    @repository = params[:repository]
    begin
    @buildresult = Buildresult.find_hashed(:project => @project, :package => @package,
      :repository => @repository, :view => ['binarylist', 'status'] )
    rescue ActiveXML::Transport::Error => e
      flash[:error] = e.message
      redirect_back_or_to :controller => 'package', :action => 'show', :project => @project, :package => @package and return
    end
    unless @buildresult
      flash[:error] = "Package \"#{@package}\" has no build result for repository #{@repository}"
      redirect_to :controller => 'package', :action => :show, :project => @project, :package => @package, :nextstatus => 404 and return
    end
  end

  def users
    @users = [@project.users, @package.users].flatten.uniq.sort
    @groups = [@project.groups, @package.groups].flatten.uniq
    @roles = Role.local_roles
  end

  def requests
    @default_request_type = params[:type] if params[:type]
    @default_request_state = params[:state] if params[:state]
  end

  def commit
    required_parameters :revision
    render partial: 'commit_item', locals: {rev: params[:revision] }
  end

  def revisions
    unless @package.api_obj.check_source_access?
      flash[:error] = 'Could not access revisions'
      redirect_to :action => :show, :project => @project.name, :package => @package.name and return
    end
    @max_revision = @package.api_obj.rev.to_i
    @upper_bound = @max_revision
    if params[:showall]
      @package.cacheAllCommits # we need to fetch commits alltogether for the cache and not each single one
      @visible_commits = @max_revision
    else
      @upper_bound = params[:rev].to_i if params[:rev]
      @visible_commits = [9, @upper_bound].min # Don't show more than 9 requests
    end
    @lower_bound = [1, @upper_bound - @visible_commits + 1].max
  end

  def submit_request_dialog
    if params[:revision]
      @revision = params[:revision]
    else
      @revision = @package.api_obj.rev
    end
    @cleanup_source = @project.name.include?(':branches:') # Rather ugly decision finding...
    render_dialog
  end

  def submit_request
    required_parameters :project, :package
    if params[:targetproject].nil? or params[:targetproject].empty?
      flash[:error] = 'Please provide a target for the submit request'
      redirect_to :action => :show, :project => params[:project], :package => params[:package] and return
    end

    begin
      params[:type] = 'submit'
      if not params[:sourceupdate] and params[:project].include?(':branches:')
        params[:sourceupdate] = 'update' # Avoid auto-removal of branch
      end
      req = Webui::BsRequest.new(params)
      req.save(:create => true)
    rescue ActiveXML::Transport::Error, ActiveXML::Transport::NotFoundError => e
      flash[:error] = "Unable to submit: #{e.message}"
      redirect_to(:action => 'show', :project => params[:project], :package => params[:package]) and return
    end

    # Supersede logic has to be below addition as we need the new request id
    if params[:supersede]
      pending_requests = Webui::BsRequest.list(:project => params[:targetproject], :package => params[:package], :states => %w(new review declined), :types => %w(submit))
      pending_requests.each do |request|
        next if request.value(:id) == req.value(:id) # ignore newly created request
        begin
          Webui::BsRequest.modify(request.value(:id), 'superseded', :reason => "Superseded by request #{req.value(:id)}", :superseded_by => req.value(:id))
        rescue BsRequest::ModifyError => e
          flash[:error] = e.message
          redirect_to(:action => 'requests', :project => params[:project], :package => params[:package]) and return
        end
      end
    end

    Rails.cache.delete 'requests_new'
    flash[:notice] = "Created <a href='#{url_for(:controller => 'request', :action => 'show', :id => req.value('id'))}'>submit request #{req.value('id')}</a> to <a href='#{url_for(:controller => 'project', :action => 'show', :project => params[:targetproject])}'>#{params[:targetproject]}</a>"
    redirect_to(:action => 'show', :project => params[:project], :package => params[:package])
  end

  def set_file_details
    @forced_unexpand ||= ''

    # check source access
    return false unless @package.api_obj.check_source_access?

    begin
      @current_rev = @package.api_obj.rev
      if not @revision and not @srcmd5
        # on very first page load only
        @revision = @current_rev
      end

      if @srcmd5
        @files = @package.files(@srcmd5, @expand)
      else
        @files = @package.files(@revision, @expand)
      end
      @linkinfo = @package.linkinfo
    rescue ActiveXML::Transport::Error => e
      if @expand == 1
        @forced_unexpand = e.summary
        @forced_unexpand = e.details if e.details
        @expand = 0
        return set_file_details
      end
      @files = []
      return false
    end

    @spec_count = 0
    @files.each do |file|
      @spec_count += 1 if file[:ext] == 'spec'
      if file[:name] == '_link'
        begin
          @link = Link.find(:project => @project, :package => @package, :rev => @revision )
        rescue RuntimeError
          # possibly thrown on bad link files
        end
      end
    end

    # check source service state
    serviceerror = nil
    serviceerror = @package.serviceinfo.value(:error) if @package.serviceinfo

    return true
  end
  private :set_file_details

  def add_person
    @roles = Role.local_roles
  end

  def add_group
    @roles = Role.local_roles
  end

  def find_last_req
    if @oproject and @opackage
      last_req = BsRequestAction.where(target_project: @oproject,
                                       target_package: @opackage,
                                       source_project: @package.project,
                                       source_package: @package.name).order(:bs_request_id).last
      return nil unless last_req
      last_req = last_req.bs_request
      if last_req.state != :declined
        return nil # ignore all !declined
      end
      return { id: last_req.id,
               decliner: last_req.commenter,
               when: last_req.updated_at,
               comment: last_req.comment }
    end
    return nil
  end

  class DiffError < APIException
  end

  def get_diff(path)
    begin
      @rdiff = ActiveXML.backend.direct_http URI(path + '&expand=1'), method: 'POST', timeout: 10
    rescue ActiveXML::Transport::Error => e
      flash[:error] = 'Problem getting expanded diff: ' + e.summary
      begin
        @rdiff = ActiveXML.backend.direct_http URI(path + '&expand=0'), method: 'POST', timeout: 10
      rescue ActiveXML::Transport::Error => e
        flash[:error] = 'Error getting diff: ' + e.summary
        redirect_back_or_to package_show_path(project: @project, package: @package)
        return false
      end
    end
    return true
  end


  def rdiff
    @last_rev = @package.api_obj.dir_hash['rev']
    @linkinfo = @package.linkinfo
    @oproject, @opackage = params[:oproject], params[:opackage]

    @last_req = find_last_req

    @rev = params[:rev] || @last_rev

    query = {'cmd' => 'diff', 'view' => 'xml', 'withissues' => 1}
    [:orev, :opackage, :oproject].each do |k|
      query[k] = params[k] unless params[k].blank?
    end
    query[:rev] = @rev if @rev
    return unless get_diff(@package.api_obj.source_path + "?#{query.to_query}")

    # we only look at [0] because this is a generic function for multi diffs - but we're sure we get one
    filenames = sorted_filenames_from_sourcediff(@rdiff)[0]
    @files = filenames['files']
    @filenames = filenames['filenames']

  end

  def wizard_new
    if params[:name]
      if !valid_package_name_write? params[:name]
        flash[:error] = "Invalid package name: '#{params[:name]}'"
        redirect_to :action => 'wizard_new', :project => params[:project]
      else
        @package = Webui::Package.new( :name => params[:name], :project => @project )
        if @package.save
          redirect_to :action => 'wizard', :project => params[:project], :package => params[:name]
        else
          flash[:notice] = "Failed to save package '#{@package}'"
          redirect_to :controller => 'project', :action => 'show', :project => params[:project]
        end
      end
    end
  end

  def wizard
    files = params[:wizard_files]
    fnames = {}
    if files
      logger.debug "files: #{files.inspect}"
      files.each_key do |key|
        file = files[key]
        next if ! file.respond_to?(:original_filename)
        fname = file.original_filename
        fnames[key] = fname
        # TODO: reuse code from PackageController#save_file and add_file.rhtml
        # to also support fetching remote urls
        @package.save_file :file => file, :filename => fname
      end
    end
    other = params[:wizard]
    if other
      response = other.merge(fnames)
    elsif ! fnames.empty?
      response = fnames
    else
      response = nil
    end
    @wizard = Wizard.find(:project => params[:project],
      :package => params[:package],
      :response => response)
  end


  def save_new
    @package_name = params[:name]
    @package_title = params[:title]
    @package_description = params[:description]

    if !valid_package_name_write? params[:name]
      flash[:error] = "Invalid package name: '#{params[:name]}'"
      redirect_to :controller => :project, :action => 'new_package', :project => @project
      return
    end
    if Webui::Package.exists? @project, @package_name
      flash[:error] = "Package '#{@package_name}' already exists in project '#{@project}'"
      redirect_to :controller => :project, :action => 'new_package', :project => @project
      return
    end

    @package = Webui::Package.new( :name => params[:name], :project => @project )
    @package.title.text = params[:title]
    @package.description.text = params[:description]
    if params[:source_protection]
      @package.add_element 'sourceaccess'
      @package.sourceaccess.add_element 'disable'
    end
    if params[:disable_publishing]
      @package.add_element 'publish'
      @package.publish.add_element 'disable'
    end
    if @package.save
      flash[:notice] = "Package '#{@package}' was created successfully"
      Rails.cache.delete('%s_packages_mainpage' % @project)
      Rails.cache.delete('%s_problem_packages' % @project)
      Webui::Package.free_cache( :all, :project => @project.name )
      Webui::Package.free_cache( @package.name, :project => @project )
      redirect_to :action => 'show', :project => params[:project], :package => params[:name]
    else
      flash[:notice] = "Failed to create package '#{@package}'"
      redirect_to :controller => 'project', :action => 'show', :project => params[:project]
    end
  end

  def branch_dialog
    render_dialog
  end

  def branch
    begin
      path = "/source/#{CGI.escape(params[:project])}/#{CGI.escape(params[:package])}?cmd=branch"
      result = ActiveXML::Node.new(frontend.transport.direct_http( URI(path), :method => 'POST', :data => ''))
      result_project = result.find_first( "/status/data[@name='targetproject']" ).text
      result_package = result.find_first( "/status/data[@name='targetpackage']" ).text
    rescue ActiveXML::Transport::Error => e
      message = e.summary
      if e.code == 'double_branch_package'
        flash[:notice] = 'You already branched the package and got redirected to it instead'
        bprj, bpkg = message.split('exists: ')[1].split('/', 2) # Hack to find out branch project / package
        redirect_to :controller => 'package', :action => 'show', :project => bprj, :package => bpkg and return
      else
        flash[:error] = message
        redirect_to :controller => 'package', :action => 'show', :project => params[:project], :package => params[:package] and return
      end
    end
    flash[:success] = "Branched package #{@project} / #{@package}"
    redirect_to :controller => 'package', :action => 'show',
      :project => result_project, :package => result_package and return
  end


  def save_new_link
    @linked_project = params[:linked_project].strip
    @linked_package = params[:linked_package].strip
    @target_package = params[:target_package].strip
    @use_branch     = true if params[:branch]
    @revision       = nil
    @current_revision = true if params[:current_revision]

    if !valid_package_name_write? @linked_package
      flash[:error] = "Invalid package name: '#{@linked_package}'"
      redirect_to :controller => :project, :action => 'new_package_branch', :project => params[:project] and return
    end

    if !valid_project_name? @linked_project
      flash[:error] = "Invalid project name: '#{@linked_project}'"
      redirect_to :controller => :project, :action => 'new_package_branch', :project => params[:project] and return
    end

    linked_package = Webui::Package.find(@linked_package, :project => @linked_project)
    unless linked_package
      flash[:error] = "Unable to find package '#{@linked_package}' in project '#{@linked_project}'."
      redirect_to :controller => :project, :action => 'new_package_branch', :project => @project and return
    end

    @target_package = @linked_package if @target_package.blank?
    if !valid_package_name_write? @target_package
      flash[:error] = "Invalid target package name: '#{@target_package}'"
      redirect_to :controller => :project, :action => 'new_package_branch', :project => @project and return
    end
    if Webui::Package.exists? @project, @target_package
      flash[:error] = "Package '#{@target_package}' already exists in project '#{@project}'"
      redirect_to :controller => :project, :action => 'new_package_branch', :project => @project and return
    end

    dirhash = linked_package.api_obj.dir_hash
    revision = dirhash['xsrcmd5'] || dirhash['rev']
    unless revision
      flash[:error] = "Unable to branch package '#{@target_package}', it has no source revision yet"
      redirect_to :controller => :project, :action => 'new_package_branch', :project => @project and return
    end

    @revision = revision if @current_revision

    if @use_branch
      logger.debug "link params doing branch: #{@linked_project}, #{@linked_package}"
      begin
        path = linked_package.api_obj.source_path('', { cmd: :branch, target_project: @project.name, target_package: @target_package})
        path += "&rev=#{CGI.escape(@revision)}" if @revision
        frontend.transport.direct_http( URI(path), :method => 'POST', :data => '')
        flash[:success] = "Branched package #{@project.name} / #{@target_package}"
      rescue ActiveXML::Transport::Error => e
        flash[:error] = e.summary
      end
    else
      # construct container for link
      package = Webui::Package.new( :name => @target_package, :project => @project )
      package.title.text = linked_package.title.text

      description = 'This package is based on the package ' +
        "'#{@linked_package}' from project '#{@linked_project}'.\n\n"

      description += linked_package.description.text if linked_package.description.text
      package.description.text = description

      begin
        saved = package.save
      rescue ActiveXML::Transport::ForbiddenError => e
        saved = false
        flash[:error] = e.summary
        redirect_to :controller => 'project', :action => 'new_package_branch', :project => @project and return
      end

      unless saved
        flash[:notice] = "Failed to save package '#{package}'"
        redirect_to :controller => 'project', :action => 'new_package_branch', :project => @project and return
        logger.debug "link params: #{@linked_project}, #{@linked_package}"
        link = Link.new( :project => @project,
          :package => @target_package, :linked_project => @linked_project, :linked_package => @linked_package )
        link.set_revision @revision if @revision
        link.save
        flash[:success] = "Successfully linked package '#{@linked_package}'"
      end
    end

    Rails.cache.delete('%s_packages_mainpage' % @project)
    Rails.cache.delete('%s_problem_packages' % @project)
    Webui::Package.free_cache( :all, :project => @project.name )
    Webui::Package.free_cache( @target_package, :project => @project )
    redirect_to :controller => 'package', :action => 'show', :project => @project, :package => @target_package
  end

  def save
    @package.title.text = params[:title]
    @package.description.text = params[:description]
    if @package.save
      flash[:notice] = "Package data for '#{@package.name}' was saved successfully"
    else
      flash[:notice] = "Failed to save package '#{@package.name}'"
    end
    redirect_to :action => 'show', :project => params[:project], :package => params[:package]
  end

  def delete_dialog
    render_dialog
  end

  def remove
    begin
      FrontendCompat.new.delete_package :project => @project, :package => @package
      flash[:notice] = "Package '#{@package}' was removed successfully from project '#{@project}'"
      Rails.cache.delete('%s_packages_mainpage' % @project)
      Rails.cache.delete('%s_problem_packages' % @project)
      Webui::Package.free_cache( :all, :project => @project.name )
      Webui::Package.free_cache( @package.name, :project => @project.name )
    rescue ActiveXML::Transport::Error => e
      flash[:error] = e.summary
    end
    redirect_to :controller => 'project', :action => 'show', :project => @project
  end

  def add_file
    set_file_details
  end

  def save_file
    file = params[:file]
    file_url = params[:file_url]
    filename = params[:filename]

    if !file.blank?
      # we are getting an uploaded file
      filename = file.original_filename if filename.blank?

      if !valid_file_name?(filename)
        flash[:error] = "'#{filename}' is not a valid filename."
        redirect_back_or_to :action => 'add_file', :project => params[:project], :package => params[:package] and return
      end

      if !@package.save_file :file => file, :filename => filename
        flash[:error] = @package.last_save_error.summary
        redirect_back_or_to :action => 'add_file', :project => params[:project], :package => params[:package] and return
      end
    elsif not file_url.blank?
      # we have a remote file uri
      @services = Service.find(:project => @project, :package => @package )
      unless @services
        @services = Service.new( :project => @project, :package => @package )
      end
      begin
        if @services.addDownloadURL(file_url)
           @services.save
           Service.free_cache :project => @project, :package => @package
        else
          raise 'foo' # same result as if an exception was thrown (will be catched in the surrounding block)
        end
      rescue
         flash[:error] = "Failed to add file from URL '#{file_url}'."
         redirect_back_or_to :action => 'add_file', :project => params[:project], :package => params[:package] and return
      end
    else
      if filename.blank?
        flash[:error] = 'No file or URI given.'
        redirect_back_or_to :action => 'add_file', :project => params[:project], :package => params[:package] and return
      else
        if !valid_file_name?(filename)
          flash[:error] = "'#{filename}' is not a valid filename."
          redirect_back_or_to :action => 'add_file', :project => params[:project], :package => params[:package] and return
        end
        if !@package.save_file :filename => filename
          flash[:error] = @package.last_save_error.summary
          redirect_back_or_to :action => 'add_file', :project => params[:project], :package => params[:package] and return
        end
      end
    end

    flash[:success] = "The file #{filename} has been added."
    redirect_to :action => :show, :project => @project, :package => @package
  end

  def remove_file
    required_parameters :filename
    filename = params[:filename]
    # extra escaping of filename (workaround for rails bug)
    escaped_filename = URI.escape filename, '+'
    if @package.remove_file escaped_filename
      flash[:notice] = "File '#{filename}' removed successfully"
      # TODO: remove patches from _link
    else
      flash[:notice] = "Failed to remove file '#{filename}'"
    end
    redirect_to :action => :show, :project => @project, :package => @package
  end

  def load_obj
    if login = params[:userid]
      return User.find_by_login!(login)
    elsif title = params[:groupid]
      return ::Group.find_by_title!(title)
    else
      raise MissingParameterError, 'Neither user nor group given'
    end
  end

  def save_person
    begin
      @package.api_obj.add_role(load_obj, Role.find_by_title!(params[:role]))
      @package.free_cache
    rescue User::NotFound, ::Group::NotFound => e
      flash[:error] = e.to_s
      redirect_to action: :add_person, project: @project, package: @package, role: params[:role], userid: params[:userid]
      return
    end
    respond_to do |format|
      format.js { render json: { status: 'ok' } }
      format.html do
        flash[:notice] = "Added user #{params[:userid]} with role #{params[:role]}"
        redirect_to action: :users, package: @package, project: @project
      end
    end
  end

  def save_group
    begin
      @package.api_obj.add_role(load_obj, Role.find_by_title!(params[:role]))
      @package.free_cache
    rescue User::NotFound, ::Group::NotFound => e
      flash[:error] = e.to_s
      redirect_to action: :add_group, project: @project, package: @package, role: params[:role], groupid: params[:groupid]
      return
    end
    respond_to do |format|
      format.js { render json: { status: 'ok' } }
      format.html do
        flash[:notice] = "Added group #{params[:groupid]} with role #{params[:role]} to package #{@package}"
        redirect_to action: :users, package: @package, project: @project
      end
    end
  end

  def remove_role
    begin
      @package.api_obj.remove_role(load_obj,  Role.find_by_title(params[:role]))
      @package.free_cache
    rescue User::NotFound, ::Group::NotFound => e
      flash[:error] = e.summary
    end
    respond_to do |format|
      format.js { render json: { status: 'ok' } }
      format.html do
        if params[:userid]
          flash[:notice] = "Removed user #{params[:userid]}"
        else
          flash[:notice] = "Removed group '#{params[:groupid]}'"
        end
        redirect_to action: :users, package: @package, project: @project
      end
    end
  end

  def view_file
    @filename = params[:filename] || params[:file] || ''
    if Webui::Package.is_binary_file?(@filename) # We don't want to display binary files
      flash[:error] = "Unable to display binary file #{@filename}"
      redirect_back_or_to :action => :show, :project => @project, :package => @package and return
    end
    @rev = params[:rev]
    @expand = params[:expand]
    @addeditlink = false
    if User.current.can_modify_package?(@package.api_obj) && @rev.blank?
      begin
        files = @package.files(@rev, @expand)
      rescue ActiveXML::Transport::Error => e
        files = []
      end
      files.each do |file|
        if file[:name] == @filename
          @addeditlink = file[:editable]
          break
        end
      end
    end
    begin
      @file = frontend.get_source(:project => @project.to_s, :package => @package.to_s, :filename => @filename, :rev => @rev, :expand => @expand)
    rescue ActiveXML::Transport::NotFoundError => e
      flash[:error] = "File not found: #{@filename}"
      redirect_to :action => :show, :package => @package, :project => @project and return
    rescue ActiveXML::Transport::Error => e
      flash[:error] = "Error: #{e}"
      redirect_back_or_to :action => :show, :project => @project, :package => @package and return
    end
    if @spider_bot
      render :template => 'package/simple_file_view' and return
    end
  end

  def save_modified_file
    check_ajax
    required_parameters :project, :package, :filename, :file
    project = params[:project]
    package = params[:package]
    filename = params[:filename]
    params[:file].gsub!( /\r\n/, "\n" )
    begin
      frontend.put_file(params[:file], :project => project, :package => package, :filename => filename, :comment => params[:comment])
      Directory.free_cache(:project => project, :package => package)
    rescue Timeout::Error => e
      render json: { error: 'Timeout when saving file. Please try again.'
      }, status: 400
      return
    rescue ActiveXML::Transport::Error => e
      render json: { error: e.summary }, status: 400
      return
    end
    render json: { status: 'ok' }
  end

  class RawOutPutStreamer
    def initialize(frontend, project, package, repository, arch)
      @frontend = frontend
      @project = project
      @package = package
      @repository = repository
      @arch = arch
      @offset = 0
      @maxsize = 1024 * 256
    end

    def each
      begin
        chunk = @frontend.get_log_chunk(@project, @package, @repository, @arch, @offset, @offset + @maxsize )
      rescue ActiveXML::Transport::Error
        return
      end
      if chunk.length == 0
        return
      end
      @offset += ActiveXML::api.last_body_length
      yield chunk
    end
  end

  def try_volley(path)
    # apache & mod_xforward case
    if CONFIG['use_xforward'] and CONFIG['use_xforward'] != 'false'
      logger.debug "[backend] VOLLEY(mod_xforward): #{path}"
      headers['X-Forward'] = "#{CONFIG['frontend_protocol']}://#{CONFIG['frontend_host']}:#{CONFIG['frontend_port']}#{path}"
      head(200)
      return true
    end

    # lighttpd 1.5 case
    if CONFIG['use_lighttpd_x_rewrite']
      headers['X-Rewrite-URI'] = path
      headers['X-Rewrite-Host'] = CONFIG['frontend_host']
      head(200)
      return true
    end

    # nginx case
    if CONFIG['use_nginx_redirect']
      headers['X-Accel-Redirect'] = "#{CONFIG['use_nginx_redirect']}/#{CONFIG['frontend_protocol']}/#{CONFIG['frontend_host']}:#{CONFIG['frontend_port']}#{path}"
      head(200)
      return true
    end

    headers['Content-Type'] = 'text/plain'
    return false
  end

  def rawsourcefile
    opts = {}
    opts[:rev] = params[:srcmd5] if params[:srcmd5].present?
    path = ::Package.source_path(params[:project], params[:package], params[:filename], opts)

    return if try_volley(path)
    begin
      self.response_body = frontend.transport.direct_http URI(path), timeout: 500
    rescue ActiveXML::Transport::NotFoundError => e
      flash[:error] = "Error: #{e.summary}"
      redirect_back_or_to :action => :show, :project => params[:project], :package => params[:package]
    end
  end

  def rawlog
    path = "/build/#{params[:project]}/#{params[:repository]}/#{params[:arch]}/#{params[:package]}/_log"

    return if try_volley(path)
    self.response_body = RawOutPutStreamer.new(frontend, params[:project], params[:package], params[:repository], params[:arch])
  end

  def live_build_log
    required_parameters :arch, :repository
    @arch = params[:arch]
    @repo = params[:repository]
    begin
      size = frontend.get_size_of_log(@project, @package, @repo, @arch)
      logger.debug('log size is %d' % size)
      @offset = size - 32 * 1024
      @offset = 0 if @offset < 0
      @initiallog = frontend.get_log_chunk( @project, @package, @repo, @arch, @offset, size)
    rescue => e
      logger.error "Got #{e.class}: #{e.message}; returning empty log."
      @initiallog = ''
    end
    @offset = (@offset || 0) + ActiveXML::api.last_body_length
  end


  def update_build_log
    check_ajax

    @project = params[:project]
    @package = params[:package]
    @arch = params[:arch]
    @repo = params[:repository]
    @initial = params[:initial]
    @offset = params[:offset].to_i
    @finished = false
    @maxsize = 1024 * 64

    begin
      @log_chunk = frontend.get_log_chunk( @project, @package, @repo, @arch, @offset, @offset + @maxsize)

      if( @log_chunk.length == 0 )
        @finished = true
      else
        @offset += ActiveXML::api.last_body_length
      end

    rescue Timeout::Error, IOError
      @log_chunk = ''

    rescue ActiveXML::Transport::Error => e
      if e.summary =~ %r{Logfile is not that big}
        @log_chunk = ''
      else
        @log_chunk = "No live log available: #{e.summary}\n"
        @finished = true
      end
    end

    logger.debug 'finished ' + @finished.to_s

  end

  def abort_build
    params[:redirect] = 'live_build_log'
    api_cmd('abortbuild', params)
  end


  def trigger_rebuild
    api_cmd('rebuild', params)
  end

  def wipe_binaries
    api_cmd('wipe', params)
  end

  def devel_project
    check_ajax
    required_parameters :package, :project
    tgt_pkg = Webui::Package.find( params[:package], project: params[:project] )
    if tgt_pkg and tgt_pkg.has_element?(:devel)
      render :text => tgt_pkg.devel.project
    else
      render :text => ''
    end
  end

  def api_cmd(cmd, params)
    options = {}
    options[:arch] = params[:arch] if params[:arch]
    options[:repository] = params[:repo] if params[:repo]
    options[:project] = @project.to_s
    options[:package] = @package.to_s

    begin
      frontend.cmd cmd, options
    rescue ActiveXML::Transport::Error => e
      flash[:error] = e.summary
      redirect_to :action => :show, :project => @project, :package => @package and return
    end

    logger.debug( "Triggered #{cmd} for #{@project}/#{@package}, options=#{options.inspect}" )
    @message = "Triggered #{cmd} for #{@project}/#{@package}."
    controller = 'package'
    action = 'show'
    if  params[:redirect] == 'monitor'
      controller = 'project'
      action = 'monitor'
    end

    unless request.xhr?
      # non ajax request:
      flash[:notice] = @message
      redirect_to :controller => controller, :action => action,
        :project => @project, :package => @package
    else
      # ajax request - render default view: in this case 'trigger_rebuild.rjs'
      return
    end
  end
  private :api_cmd

  def import_spec
    all_files = @package.files
    all_files.each do |file|
      @specfile_name = file[:name] if file[:name].end_with?('.spec')
    end
    if @specfile_name.blank?
      render json: {} and return
    end
    specfile_content = frontend.get_source(
      project: params[:project], package: params[:package], filename: @specfile_name
    )

    description = []
    lines = specfile_content.split(/\n/)
    line = lines.shift until line =~ /^%description\s*$/
    description << lines.shift until description.last =~ /^%/
    # maybe the above end-detection of the description-section could be improved like this:
    # description << lines.shift until description.last =~ /^%\{?(debug_package|prep|pre|preun|....)/
    description.pop

    render json: { description: description }
  end

  def buildresult
    check_ajax
    # discard cache
    @buildresult = Buildresult.find_hashed( :project => @project, :package => @package, :view => 'status')
    fill_status_cache unless @buildresult.blank?
    render :partial => 'buildstatus'
  end

  def rpmlint_result
    check_ajax
    @repo_list, @repo_arch_hash = [], {}
    @buildresult = Buildresult.find_hashed(:project => @project, :package => @package, :view => 'status')
    repos = [] # Temp var
    @buildresult.elements('result') do |result|
      hash_key = valid_xml_id(elide(result.value('repository'), 30))
      @repo_arch_hash[hash_key] ||= []
      @repo_arch_hash[hash_key] << result['arch']
      repos << result.value('repository')
    end if @buildresult
    repos.uniq.each do |repo_name|
      @repo_list << [repo_name, valid_xml_id(elide(repo_name, 30))]
    end
    if @repo_list.empty?
      render partial: 'no_repositories'
    else
      render partial: 'rpmlint_result', locals: {index: params[:index]}
    end
  end

  def get_rpmlint_log(project, package, repository, architecture)
    path = "/build/#{pesc project}/#{pesc repository}/#{pesc architecture}/#{pesc package}/rpmlint.log"
    ActiveXML::backend.direct_http(URI(path), timeout: 500)
  end

  def rpmlint_log
    required_parameters :project, :package, :repository, :architecture
    begin
      rpmlint_log = get_rpmlint_log(params[:project], params[:package], params[:repository], params[:architecture])
      rpmlint_log.encode!(xml: :text)
      res = ''
      rpmlint_log.lines.each do |line|
        if line.match(/\w+(?:\.\w+)+: W: /)
          res += "<span style=\"color: olive;\">#{line}</span>"
        elsif line.match(/\w+(?:\.\w+)+: E: /)
          res += "<span style=\"color: red;\">#{line}</span>"
        else
          res += line
        end
      end
      render :text => res, content_type: 'text/html'
    rescue ActiveXML::Transport::NotFoundError
      render :text => 'No rpmlint log'
    end
  end

  def meta
    @meta = @package.api_obj.render_xml
  end

  def save_meta
    begin
      frontend.put_file(params[:meta], :project => @project, :package => @package, :filename => '_meta')
    rescue ActiveXML::Transport::Error => e
      message = e.summary
      flash[:error] = message
      @meta = params[:meta]
      render :text => message, :status => 400, :content_type => 'text/plain'
      return
    end

    flash[:notice] = 'Config successfully saved'
    @package.free_cache
    render :text => 'Config successfully saved', :content_type => 'text/plain'
  end

  def attributes
    if @project.is_remote?
      @attributes = nil
    else
      @attributes = Attribute.find(:project => @project.name, :package => @package.to_s)
    end
  end

  def edit
  end

  def repositories
    @flags = @package.api_obj.expand_flags
  end

  def change_flag
    check_ajax
    required_parameters :cmd, :flag
    frontend.source_cmd params[:cmd], project: @project, package: @package, repository: params[:repository], arch: params[:arch], flag: params[:flag], status: params[:status]
    @flags = @package.api_obj.expand_flags[params[:flag]]
  end

  private

  def file_available? url, max_redirects=5
    uri = URI.parse( url )
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 15
    http.read_timeout = 15
    logger.debug "Checking url: #{url}"
    begin
      response =  http.head uri.path
      if response.code.to_i == 302 and response['location'] and max_redirects > 0
        return file_available? response['location'], (max_redirects - 1)
      end
      return response.code.to_i == 200 ? true : false
    rescue Object => e
      logger.error "Error in checking for file #{url}: #{e.message}"
      return false
    end
  end

  def require_project
    required_parameters :project
    if !valid_project_name? params[:project]
      unless request.xhr?
        flash[:error] = "#{params[:project]} is not a valid project name"
        redirect_to :controller => 'project', :action => 'list_public', :nextstatus => 404 and return
      else
        render :text => "#{params[:project]} is not a valid project name", :status => 404 and return
      end
    end
    @project = WebuiProject.find( params[:project] )
    unless @project
      unless request.xhr?
        flash[:error] = "Project not found: #{params[:project]}"
        redirect_to :controller => 'project', :action => 'list_public', :nextstatus => 404 and return
      else
        render :text => "Project not found: #{params[:project]}", :status => 404 and return
      end
    end
  end

  def require_package
    required_parameters :package
    params[:rev], params[:package] = params[:pkgrev].split('-', 2) if params[:pkgrev]
    unless valid_package_name_read? params[:package]
      logger.error "Package #{@project}/#{params[:package]} not valid"
      unless request.xhr?
        flash[:error] = "\"#{params[:package]}\" is not a valid package name"
        redirect_to :controller => 'project', :action => 'show', :project => @project, :nextstatus => 404 and return
      else
        render :text => "\"#{params[:package]}\" is not a valid package name", :status => 404 and return
      end
    end
    @project ||= params[:project]
    unless params[:package].blank?
      begin
        @package = Webui::Package.find( params[:package], :project => @project )
      rescue ActiveXML::Transport::Error => e
        flash[:error] = e.message
        unless request.xhr?
          redirect_to :controller => 'project', :action => 'show', :project => @project, :nextstatus => 400 and return
        else
        render :text => e.message, :status => 404 and return
        end
      end
    end
    unless @package
      unless request.xhr?
        flash[:error] = "Package \"#{params[:package]}\" not found in project \"#{params[:project]}\""
        redirect_to :controller => 'project', :action => 'show', :project => @project, :nextstatus => 404
      else
        render :text => "Package \"#{params[:package]}\" not found in project \"#{params[:project]}\"", :status => 404 and return
      end
    end
  end

  def fill_status_cache
    @repohash = Hash.new
    @statushash = Hash.new
    @packagenames = Array.new
    @repostatushash = Hash.new
    @failures = 0

    @buildresult.elements('result') do |result|
      @resultvalue = result
      repo = result['repository']
      arch = result['arch']

      @repohash[repo] ||= Array.new
      @repohash[repo] << arch

      # package status cache
      @statushash[repo] ||= Hash.new
      @statushash[repo][arch] = Hash.new

      stathash = @statushash[repo][arch]
      result.elements('status') do |status|
        stathash[status['package']] = status
        if ['unresolvable', 'failed', 'broken'].include? status['code']
          @failures += 1
        end
      end

      # repository status cache
      @repostatushash[repo] ||= Hash.new
      @repostatushash[repo][arch] = Hash.new

      if result.has_key? 'state'
        if result.has_key? 'dirty'
          @repostatushash[repo][arch] = 'outdated_' + result['state']
        else
          @repostatushash[repo][arch] = result['state']
        end
      end

      @packagenames << stathash.keys
    end

    if @buildresult and !@buildresult.has_key? 'result'
      @buildresult = nil
    end

    return unless @buildresult

    newr = Hash.new
    @buildresult.elements('result').sort {|a,b| a['repository'] <=> b['repository']}.each do |result|
      repo = result['repository']
      if result.has_key? 'status'
        newr[repo] ||= Array.new
        newr[repo] << result['arch']
      end
    end

    @buildresult = Array.new
    newr.keys.sort.each do |r|
      @buildresult << [r, newr[r].flatten.sort]
    end
  end

end
end