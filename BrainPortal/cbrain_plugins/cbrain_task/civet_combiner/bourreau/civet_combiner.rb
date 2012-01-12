
#
# CBRAIN Project
#
# CbrainTask subclass for combining a set of partial
# CIVET results into a single larger CIVET result.
#
# Original author: Pierre Rioux
#
# $Id$
#

# A subclass of ClusterTask to combine CIVET results.
class CbrainTask::CivetCombiner < ClusterTask

  Revision_info=CbrainFileRevision[__FILE__]

  include RestartableTask # This task is naturally restartable
  include RecoverableTask # This task is naturally recoverable

  def setup #:nodoc:
    params       = self.params

    # List of collection IDs directly supplied
    civet_collection_ids = params[:civet_collection_ids] || [] # used to be string
    civet_ids            = civet_collection_ids.is_a?(Array) ? civet_collection_ids : civet_collection_ids.split(/,/)

    # Fetch list of collection IDs indirectly through task list
    task_list_ids        = params[:civet_from_task_ids] || ""
    task_ids             = task_list_ids.split(/,/)
    civet_collection_ids = [] if ! task_ids.empty? # with a task ID list, we ignore the original civet_collection_ids
    task_ids.each do |tid|
      task    = CbrainTask.find(tid)
      tparams = task.params
      cid     = tparams[:output_civetcollection_id]  # old a single id
      cids    = tparams[:output_civetcollection_ids] # new, an array
      cb_error "Could not found any output CIVET collection IDs from task '#{task.bname_tid}'." if cid.blank? && cids.blank?
      civet_ids << cid  unless cid.blank?
      civet_ids += cids unless cids.blank?
    end

    # Save back full list of all collection IDs into params
    civet_ids = civet_ids.map(&:to_s).uniq.sort
    params[:civet_collection_ids] = civet_ids

    # Get each source collection
    cols = []
    civet_ids.each do |id|
      col = Userfile.find(id.to_i)
      unless col && (col.is_a?(CivetOutput)) # || col.is_a?(CivetStudy))
        self.addlog("Error: cannot find CivetOutput with ID=#{id}")
        return false
      end
      cols << col
    end

    if cols.empty?
      self.addlog("Error: no valid collections supplied?")
      return false
    end

    # Synchronize them all
    self.addlog("Synchronizing collections to local cache")
    cols.each do |col|
      self.addlog("Synchronizing '#{col.name}'")
      self.save # so log messages appear as syncs happen
      col.sync_to_cache
    end
    self.addlog("Synchronization finished.")

    # Choose a DP id if none was supplied; we pick the first collections' DP.
    self.results_data_provider_id ||= cols[0].data_provider_id

    # Check that all CIVET outputs have
    # 1) the same 'prefix'
    # 2) a distinct 'dsid'
    self.addlog("Checking collections: prefix and dsid...")
    seen_prefix = {}
    seen_dsid   = {}
    tcol_to_dsid = {}
    cols.each do |col|
      top = col.cache_full_path
      params_file  = top + "CBRAIN.params.yml"
      ymltext      = File.read(params_file) rescue ""
      if ymltext.blank?
        self.addlog("Could not find params file '#{params_file}' for CivetOutput '#{col.name}'.")
        return false
      end
      civet_params = YAML::load(ymltext).with_indifferent_access
      file_args = civet_params[:file_args] || { "0" => {} }
      file0     = file_args["0"]           || {}
      prefix = file0[:prefix] || civet_params[:prefix]  # change in struct: NEW || OLD
      dsid   = file0[:dsid]   || civet_params[:dsid]    # change in struct: NEW || OLD
      if prefix.blank?
        self.addlog("Could not find PREFIX for CivetOutput '#{col.name}'.")
        return false
      end
      if dsid.blank?
        self.addlog("Could not find DSID for CivetOutput '#{col.name}'.")
        return false
      end
      seen_prefix[prefix]   = true
      seen_dsid[dsid]     ||= 0
      seen_dsid[dsid]      += 1
      tcol_to_dsid["C#{col.id}"] = dsid
    end

    if seen_prefix.size != 1
      self.addlog("Error, found more than one PREFIX in the CIVET outputs: #{seen_prefix.keys.sort.join(', ')}")
      return false
    end

    prefix = seen_prefix.keys[0]

    if seen_dsid.values.select { |v| v > 1 }.size > 0
      reports = seen_dsid.map { |dsid,count| "'#{dsid}' x #{count}" }
      self.addlog("Error, found some DSIDs represented more than once: #{reports.sort.join(', ')}")
      return false
    end

    self.addlog("Combining results; PREFIX=#{prefix}, DSIDs=#{seen_dsid.keys.sort.join(', ')}")

    # Just record the PREFIX and the list of DSIDs in the task's params.
    params[:prefix] = prefix
    params[:dsids]  = tcol_to_dsid

  end

  def cluster_commands #:nodoc:
    params       = self.params

    nil   # Special case: no cluster job.
  end
  
  def save_results #:nodoc:
    params       = self.params
    provid       = self.results_data_provider_id
    newname      = params[:civet_study_name]
    prefix       = params[:prefix] # set in setup() above
    tcol_to_dsid = params[:dsids]  # set in setup() above

    # Create new CivetStudy object to hold them all
    # and in the darkness bind them
    newstudy = safe_userfile_find_or_new(CivetStudy,
      :name             => newname,
      :data_provider_id => provid
    )

    civet_collection_ids = params[:civet_collection_ids] || [] # used to be string
    civet_ids            = civet_collection_ids.is_a?(Array) ? civet_collection_ids : civet_collection_ids.split(/,/)
    # Save back full list of all collection IDs into params
    civet_ids = civet_ids.map(&:to_s).uniq.sort
    params[:civet_collection_ids] = civet_ids
    cols = civet_ids.map { |id| Userfile.find(id) }

    # Now let's fill the new CivetStudy with everything in
    # the original collections; if anything fails, we need
    # to destroy the incomplete newstudy object.

    self.addlog("Combining collections...")
    #begin
      newstudy.save!
      newstudy.cache_prepare
      self.addlog_to_userfiles_these_created_these(cols,[newstudy],"with prefix '#{prefix}'")

      coldir = newstudy.cache_full_path
      Dir.mkdir(coldir) unless File.directory?(coldir)
      errfile = self.stderr_cluster_filename

      # Issue rsync commands to combine the files
      subjects = []
      cols.each do |col|
        col_id = col.id
        dsid   = tcol_to_dsid["C#{col_id}"]
        subjects << dsid
        self.addlog("Adding #{col.class.to_s} '#{col.name}'")
        newstudy.addlog("Adding #{col.class.to_s} '#{col.name}'")
        colpath = col.cache_full_path
        dsid_dir = coldir + dsid
        Dir.mkdir(dsid_dir.to_s) unless File.directory?(dsid_dir.to_s)
        rsyncout = IO.popen("rsync -a -l '#{colpath.to_s}/' #{dsid_dir} 2>&1 | tee -a #{errfile}","r") do |fh|
          fh.read
        end
        unless rsyncout.blank?
          cb_error "Error running rsync; rsync returned '#{rsyncout}'"
        end
      end

      newstudy.save
      self.addlog("Syncing CivetStudy '#{newstudy.name}' (ID=#{newstudy.id}) to its Data Provider...")
      newstudy.sync_to_provider
      newstudy.set_size
      newstudy.save

      params[:output_civetstudy_id] = newstudy.id
      newstudy.addlog("Subjects are: #{subjects.join(", ")}")

      # Option: destroy the original sources
      if params[:destroy_sources] && params[:destroy_sources].to_s == 'YeS'
        cols.each do |col|
          self.addlog("Destroying source #{col.class.to_s} '#{col.name}'")
          col.destroy rescue true
        end
      end

    #rescue => itswrong
    #  newstudy.destroy
    #  params.delete(:output_civetstudy_id)
    #  raise itswrong
    #end

    true
  end

end

