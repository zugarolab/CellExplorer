function spikes = loadSpikes(varargin)
% This function imports various spike sorting pipelines/formats into the CellExplorer spikes format 
% Once spikes are imported and saved to a .mat file, the script will load this spikes struct instead of importing again. 
% The forceReload parameter can overrule this.
% 
% Currently supported formats: 
%      ALF
%      AllenSDK (via NWB files and their API data files)
%      Custom (Spike timestamps as input)
%      Klustakwik/Neurosuite
%      KlustaViewa/Klustasuite
%      MClust
%      NWB
%      Phy (default import format)
%      Sebastien Royer's lab standard
%      SpyKING Circus
%      UltraMegaSort2000
%      Wave_clus
%
% Please see the CellExplorer website: https://cellexplorer.org/datastructure/data-structure-and-format/#spikes
%
% INPUTS
% 
% See description of varargin below
%
% OUTPUT
%
% spikes:               - Matlab struct described here: https://cellexplorer.org/datastructure/data-structure-and-format/#spikes
%     .basename         - Name of recording file
%     .sr               - Sampling rate
%     .UID              - Unique identifier for each neuron in a recording
%     .times            - Cell array of timestamps (seconds) for each neuron
%     .spindices        - Sorted vector of [spiketime UID], useful as input to some functions and plotting rasters
%     .region           - Region ID for each neuron (especially important large scale, high density probes)
%     .maxWaveformCh    - Channel # with largest amplitude spike for each neuron (0-indexed)
%     .maxWaveformCh1   - Channel # with largest amplitude spike for each neuron (1-indexed)
%     .rawWaveform      - Average waveform on maxWaveformCh (from raw binary file)
%     .filtWaveform     - Average filtered waveform on maxWaveformCh (from raw binary file)
%     .rawWaveform_std  - Average waveform on maxWaveformCh (from raw binary file)
%     .filtWaveform_std - Average filtered waveform on maxWaveformCh (from raw binary file)
%     .peakVoltage      - Peak voltage (uV)
%     .cluID            - Cluster ID
%     .shankID          - shankID
%     .processingInfo   - Processing info
%
% DEPENDENCIES:
% - npy-matlab toolbox (required for reading phy, AllenSDK & ALF data: https://github.com/kwikteam/npy-matlab)
% - LoadXml.m: included with CellExplorer: https://github.com/petersenpeter/CellExplorer/tree/master/calc_CellMetrics/private
% - getWaveformsFromDat: included with CellExplorer
%
%
% EXAMPLE CALLS
% spikes = loadSpikes('session',session); % clustering format should be specified in the session struct
% spikes = loadSpikes('basepath',pwd,'clusteringpath','relativeOutputFolder'); % Run from basepath (pwd), assumes Phy format.
% spikes = loadSpikes('basepath',pwd,'format','mclust'); % Run from basepath, loads MClust format.
% spikes = loadSpikes('session',session,'UID',1:30,'shankID',1:3); % Loads spikes and filters output - only UID 1:30 and the first 3 electrodeGroups.
% spikes = loadSpikes('basepath',pwd,'format','custom','spikes_times',spikes_times); % Run from basepath, custom spike format, requires the spike times as input. 

% By Peter Petersen
% petersen.peter@gmail.com
% Last edited: 17-10-2022

% Version history
% 3.2 waveforms for phy data extracted from the raw dat
% 3.3 waveforms extracted from raw dat using memmap function. Interval and bad channels bugs fixed as well
% 3.4 bug fix which gave misaligned waveform extraction from raw dat. Plot improvements of waveforms
% 3.5 new name and better handling of inputs
% 3.6 All waveforms across channels extracted from raw dat file
% 3.7 Switched from xml to session struct for metadata
% 3.8 Waveforn extraction separated into its own function
% 4.1 Adding filter options (e.g. UID, shankID, cluID, region)
% 4.3 Support for SpyKING Circus

p = inputParser;
addParameter(p,'basepath',pwd,@ischar); % basepath with dat file, used to extract the waveforms from the dat file
addParameter(p,'clusteringpath',[],@ischar); % relativ clustering path to spike data (optional)
addParameter(p,'format',[],@ischar); % clustering format: phy, klustakwik/neurosuite, KlustaViewa, NWB, Wave_clus, MClust, UltraMegaSort2000, ALF, AllenSDK
                                                     % TODO: 'SpyKING CIRCUS', 'MountainSort', 'IronClust'
addParameter(p,'basename','',@ischar); % The basename file naming convention
addParameter(p,'electrodeGroups',nan,@isnumeric); % electrodeGroups: Loading only a subset of electrodeGroups from the spike format (only applicable to Klustakwik/neurosuite and KlustaViewa)
addParameter(p,'raw_clusters',false,@islogical); % raw_clusters: Load only a subset of clusters (might not work anymore as it has not been tested for a long time)
addParameter(p,'saveMat',true,@islogical); % Save spikes to mat file?
addParameter(p,'forceReload',false,@islogical); % Reload spikes from original format (overwrites existing mat file if saveMat==true)?
addParameter(p,'getWaveformsFromDat',true,@islogical); % Gets waveforms from dat (binary file). If false, the script will use waveforms from other sources.
addParameter(p,'getWaveformsFromSource',false,@islogical); % Use Waveform from processed sources. E.g. waveforms stored in Neurosuite format.
addParameter(p,'spikes',[],@isstruct); % Load existing spikes structure to append new spike info
addParameter(p,'LSB',0.195,@isnumeric); % Least significant bit (LSB in uV/bit) Intan = 0.195, Amplipex = 0.3815. (range/precision)
addParameter(p,'session',[],@isstruct); % A buzsaki lab session struct
addParameter(p,'labelsToRead',{'good'},@iscell); % allows you to load units with various labels, e.g. MUA or a custom label
addParameter(p,'showWaveforms',true,@islogical);
addParameter(p,'showGUI',false,@islogical);

% Custom spike input
addParameter(p,'spikes_times',{},@iscell); % allows you to load spike data from a cell array with timestamps (formatted as spikes.times)

% Filters - All good cells are saved to the struct but the function output can be filtered by below fields
addParameter(p,'UID',[],@isnumeric);        % Filter by UID
addParameter(p,'shankID',[],@isnumeric);    % Filter by shankID
addParameter(p,'cluID',[],@isnumeric);      % Filter by cluID
addParameter(p,'region',[],@isstring);      % Filter by brain regions

parse(p,varargin{:})

basepath = p.Results.basepath;
clusteringpath = p.Results.clusteringpath;
format = p.Results.format;
basename = p.Results.basename;
electrodeGroups = p.Results.electrodeGroups;
raw_clusters = p.Results.raw_clusters;
spikes = p.Results.spikes;
LSB = p.Results.LSB;
session = p.Results.session;
labelsToRead = p.Results.labelsToRead;
spikes_times = p.Results.spikes_times;
showGUI = p.Results.showGUI;

parameters = p.Results;

if ~isempty(session)
    basename = session.general.name;
    basepath = session.general.basePath;
elseif isempty(basename)
    basename = basenameFromBasepath(basepath);
end

if exist(fullfile(basepath,[basename,'.spikes.cellinfo.mat']),'file') && ~parameters.forceReload
    load(fullfile(basepath,[basename,'.spikes.cellinfo.mat']))
    if ~isfield(spikes,'processinginfo') || (isfield(spikes,'processinginfo') && spikes.processinginfo.version < 3 && strcmp(spikes.processinginfo.function,'loadSpikes') )
        parameters.forceReload = true;
        disp('spikes.mat structure not up to date. Reloading spikes.')
    end
elseif ~isempty(spikes)
    disp('loadSpikes: Using existing spikes file')
% elseif exist(fullfile(basepath,[basename,'.spikes.cellinfo.mat']),'file') 
%     load(fullfile(basepath,[basename,'.spikes.cellinfo.mat']))
else
    parameters.forceReload = true;
    spikes = [];
    showGUI = true;
end

% Loading spikes
if parameters.forceReload
    if isempty(session)
        session = loadSession(basepath,basename); % ,'showGUI',showGUI
        if isfield(session.extracellular,'leastSignificantBit') && session.extracellular.leastSignificantBit>0
            LSB = session.extracellular.leastSignificantBit;
        end
    end
    if ~ischar(format)
        try
            format = session.spikeSorting{1}.format;
        catch
            format = 'Phy';
        end
    end
    
    if ~ischar(clusteringpath)
        try
            clusteringpath = session.spikeSorting{1}.relativePath;
        catch
            clusteringpath = '';
        end
    end

    clusteringpath_full = fullfile(basepath,clusteringpath);
    
    % If the least significant bit is not defined, a default value will be used
    if ~isfield(session,'extracellular') || ~isfield(session.extracellular,'leastSignificantBit') || session.extracellular.leastSignificantBit == 0
        session.extracellular.leastSignificantBit = LSB; % getWaveformsFromDat also uses this
    end
    
    % If number of channels or electrode groups are missing in the session struct, the script will try to import this from a basename.sessionInfo.mat or a basename.xml file.
    if ~isfield(session.extracellular,'nChannels') || ~isfield(session.extracellular,'electrodeGroups') || ~isfield(session.extracellular,'sr')
        if exist(fullfile(session.general.basePath,[session.general.name,'.sessionInfo.mat']),'file')
            session = loadBuzcodeMetadata(session);
        elseif exist(fullfile(session.general.basePath,[session.general.name, '.xml']),'file')
            session = loadNeurosuiteMetadata(session);
        else
            session = sessionTemplate(session);
        end
        % TODO: A gui will be shown allowing for manual edits of extracellular parameters        
    end
    
    spikes = [];
    
    switch lower(format)
        case 'custom'
            nCells = numel(spikes_times);
            spikes.times = spikes_times;
            for i = 1:nCells
                spikes.cluID(i) = i;
                spikes.total(i) = length(spikes.times{i});
            end
            
        case 'phy' % Loading phy
            % Required files:
            % spike_clusters.npy    # Spike cluster indexes
            % spike_times.npy       # Spike timestamps
            %
            % Phy1: 
            % cluster_group.tsv
            %
            % Phy2: 
            % cluster_groups.csv or cluster_KSLabel.tsv
            % cluster_info
            %
            % Optional:
            % amplitudes.npy        # Spike amplitudes
            %
            % Optional (from Phy plugins):
            % cluster_ids.npy       # List of cluster ids
            % shanks.npy            # List of shank ids for the clusters in cluster_ids
            % peak_channel.npy      # List of peak channels for the clusters in cluster_ids
            % 
            
            if ~exist('readNPY.m','file')
                error('''readNPY.m'' is not in your path and is required to load the python data. Please download it here: https://github.com/kwikteam/npy-matlab.')
            end
            disp('loadSpikes: Loading Phy data')
            spike_cluster_index = readNPY(fullfile(clusteringpath_full, 'spike_clusters.npy'));
            spike_times = readNPY(fullfile(clusteringpath_full, 'spike_times.npy'));
            if exist(fullfile(clusteringpath_full, 'amplitudes.npy'),'file')
                spike_amplitudes = readNPY(fullfile(clusteringpath_full, 'amplitudes.npy'));
            end
            spike_clusters = unique(spike_cluster_index);
            file_cluster_group_tsv = fullfile(clusteringpath_full,'cluster_group.tsv');
            file_cluster_groups_csv = fullfile(clusteringpath_full,'cluster_groups.csv');
            file_cluster_KSLabel_tsv = fullfile(clusteringpath_full,'cluster_KSLabel.tsv');
            if exist(fullfile(clusteringpath_full, 'cluster_ids.npy'),'file') && exist(fullfile(clusteringpath_full, 'shanks.npy'),'file') && exist(fullfile(clusteringpath_full, 'peak_channel.npy'),'file')
                cluster_ids = readNPY(fullfile(clusteringpath_full, 'cluster_ids.npy'));
                unit_shanks = readNPY(fullfile(clusteringpath_full, 'shanks.npy'));
                peak_channel = readNPY(fullfile(clusteringpath_full, 'peak_channel.npy'))+1;
                if exist(fullfile(clusteringpath_full, 'rez.mat'),'file')
                    load(fullfile(clusteringpath_full, 'rez.mat'))
                    temp = find(rez.connected);
                    peak_channel = temp(peak_channel);
                    clear rez temp
                end
            end
            if exist(fullfile(clusteringpath_full,'cluster_info.tsv'),'file')
                cluster_info = tdfread(fullfile(clusteringpath_full,'cluster_info.tsv'));
            end
            delimiter = '\t';
            startRow = 2;
            formatSpec = '%f%s%[^\n\r]';
            if exist(file_cluster_group_tsv,'file')
                % Verifying the file is not empty
                fileID = fopen(file_cluster_group_tsv,'r');
                dataArray = textscan(fileID, formatSpec, 'Delimiter', delimiter, 'HeaderLines' ,startRow-1, 'ReturnOnError', false);
                fclose(fileID);
                if isempty(dataArray{1})
                    disp(['Noc clusters found in ', file_cluster_group_tsv,'. Will use the labels from KiloSort'])
                    filename = file_cluster_KSLabel_tsv;
                else
                    filename = file_cluster_group_tsv;
                end                    
            elseif exist(file_cluster_groups_csv,'file')
                filename = file_cluster_groups_csv;
                delimiter = ',';
            elseif exist(file_cluster_KSLabel_tsv,'file')
                filename = file_cluster_KSLabel_tsv;
            else
                error('Phy: No cluster group file found (cluster_group.tsv, cluster_groups.csv or cluster_KSLabel.tsv)')
            end
            
            fileID = fopen(filename,'r');
            dataArray = textscan(fileID, formatSpec, 'Delimiter', delimiter, 'HeaderLines' ,startRow-1, 'ReturnOnError', false);
            fclose(fileID);
            UID = 1;
            tol_samples = session.extracellular.sr*5e-4; % 0.5 ms tolerance in timestamp units
            for i = 1:length(dataArray{1})
                if raw_clusters == 0
                    if any(strcmpi(dataArray{2}{i},labelsToRead))
                        if sum(spike_cluster_index == dataArray{1}(i))>0
                            spikes.ids{UID} = find(spike_cluster_index == dataArray{1}(i));
                            [spikes.ts{UID},ind_unique] = uniquetol(double(spike_times(spikes.ids{UID})),tol_samples,'DataScale',1); % unique values within tol (<= 0.8ms)
                            spikes.ids{UID} = spikes.ids{UID}(ind_unique);
                            spikes.times{UID} = spikes.ts{UID}/session.extracellular.sr;
                            spikes.cluID(UID) = dataArray{1}(i);
                            spikes.total(UID) = length(spikes.ts{UID});
                            
                            if exist('spike_amplitudes','var')
                                spikes.amplitudes{UID} = double(spike_amplitudes(spikes.ids{UID}));
                            end
                            
                            % Phy plugins:
                            if exist('cluster_ids','var')
                                cluster_id = find(cluster_ids == spikes.cluID(UID));
                                spikes.maxWaveformCh1(UID) = double(peak_channel(cluster_id)); % index 1;
                                spikes.maxWaveformCh(UID) = double(peak_channel(cluster_id))-1; % index 0;
                                
                                % Assigning shankID to the unit
                                for jj = 1:session.extracellular.nElectrodeGroups
                                    if any(session.extracellular.electrodeGroups.channels{jj} == spikes.maxWaveformCh1(UID))
                                        spikes.shankID(UID) = jj;
                                    end
                                end
                            end
                            
                            % New file data format of phy2
                            if exist('cluster_info','var')
                                if isfield(cluster_info,'id')
                                    temp = find(cluster_info.id == spikes.cluID(UID));
                                else %in the recent(2021) version of Phy2: isfield(cluster_info,'cluster_id')
                                    temp = find(cluster_info.cluster_id == spikes.cluID(UID));
                                end
                                spikes.maxWaveformCh(UID) = cluster_info.ch(temp); % max waveform channel
                                spikes.maxWaveformCh1(UID) = cluster_info.ch(temp)+1; % index 1;
                                spikes.phy_maxWaveformCh1(UID) = cluster_info.ch(temp)+1; % index 1; saves the max waveform channel from phy as a separate variable
                                spikes.phy_amp(UID) = cluster_info.amp(temp)+1; % spike amplitude
                                % spikes.phy_purity(UID) = cluster_info.purity(temp)+1; % cluster purity                                
                            end

                            UID = UID+1;
                        end
                    end
                else
                    spikes.ids{UID} = find(spike_cluster_index == dataArray{1}(i));
                    tol = tol_ms/max(double(spike_times(spikes.ids{UID}))); % unique values within tol (=within 1 ms)
                    [spikes.ts{UID},ind_unique] = uniquetol(double(spike_times(spikes.ids{UID})),tol);
                    spikes.ids{UID} = spikes.ids{UID}(ind_unique);
                    spikes.times{UID} = spikes.ts{UID}/session.extracellular.sr;
                    spikes.cluID(UID) = dataArray{1}(i);
                    
                    if exist('spike_amplitudes','var')
                        spikes.amplitudes{UID} = double(spike_amplitudes(spikes.ids{UID}))';
                    end
                    UID = UID+1;
                end
            end

            if parameters.getWaveformsFromSource
                disp('Getting waveforms from the phy template')
                filename_templates = fullfile(clusteringpath_full,'templates.npy');
                if exist(filename_templates,'file')
                    templates = readNPY(fullfile(clusteringpath_full, 'templates.npy'));
                    spike_templates = readNPY(fullfile(clusteringpath_full, 'spike_templates.npy'));

                    for UID = 1:numel(spikes.times)
                        template_id = double(mode(spike_templates(spikes.ids{UID})));
                        spikes.filtWaveform_all{UID} = permute(double(templates(template_id,:,:)),[3 2 1]);
                        [~,idx] = max(range(spikes.filtWaveform_all{UID}'));
                        spikes.filtWaveform{UID} = double(templates(template_id,:,idx));
                    end
                end
            end

            disp(['Importing ' num2str(numel(spikes.times)),'/', num2str(length(dataArray{1})),' clusters from phy'])
            
        case {'ultramegasort2000','ums2k'} % ultramegasort2000 (https://github.com/danamics/UMS2K)
            % From the Neurophysics Lab at UCSD (Daniel N. Hill, Samar B. Mehta, David Kleinfeld)
            fileList = dir(fullfile(clusteringpath_full,['times_raw_elec_CH*.mat']));
            fileList = {fileList.name};
            UID = 1;
            for i_channel = 1:numel(fileList)
                ums2k_spikes = load(fullfile(clusteringpath_full,fileList{i_channel}),'spikes');
                ums2k_spikes = ums2k_spikes.spikes;
                for i = 1:size(ums2k_spikes.labels,1)
                    if ums2k_spikes.labels(i,2) == 2 % Only good clusters are imported (labels == 2)
                        spikes.cluID(UID) = ums2k_spikes.labels(i,1);
                        idx = ums2k_spikes.assigns == spikes.cluID(UID);
                        spikes.times{UID} = double(ums2k_spikes.spiketimes(idx))';
                        if isfield(ums2k_spikes,'trials')
                            spikes.trials{UID} = double(ums2k_spikes.trials(idx))';
                        end
                        spikes.filtWaveform{UID} = double(1000000*mean(ums2k_spikes.waveforms(idx,:)));
                        spikes.filtWaveform_std{UID} = 1000000*std(ums2k_spikes.waveforms(idx,:));
                        spikes.timeWaveform{UID} = [0:size(ums2k_spikes.waveforms,2)-1]/ums2k_spikes.params.Fs*1000 - ums2k_spikes.params.cross_time;
                        spikes.peakVoltage(UID) = double(range(spikes.filtWaveform{UID}));
                        spikes.maxWaveformCh(UID) = str2double(fileList{i_channel}(18:end-4))-1; % max waveform channel (index-0)
                        spikes.maxWaveformCh1(UID) = str2double(fileList{i_channel}(18:end-4)); % max waveform channel (index-1)
                        spikes.total(UID) = length(spikes.times{UID});
                        spikes.shankID(UID) = spikes.maxWaveformCh1(UID); % Assigning shankID to the unit
                        UID = UID+1;
                    end
                end
            end
            spikes.processinginfo.params.WaveformsSource = 'ultramegasort2000';
            
        case {'alf'} % ALF format from the cortex lab at UCL
            disp('loadSpikes: Loading ALF npy data')
            % Format described here: https://github.com/nsteinme/steinmetz-et-al-2019/wiki/data-files
            clusters_phy_annotation = readNPY(fullfile(session.general.basePath,'clusters._phy_annotation.npy')); % 0:noise,1:mua,2:good,3:other. all units >1 are accepted
            clusters_depths = readNPY(fullfile(session.general.basePath,'clusters.depths.npy')); % What is this?
            clusters_peakChannel = readNPY(fullfile(session.general.basePath,'clusters.peakChannel.npy')); % 1-indexed?
            clusters_probes = readNPY(fullfile(session.general.basePath,'clusters.probes.npy'));
            clusters_originalIDs = readNPY(fullfile(session.general.basePath,'clusters.originalIDs.npy'));
            clusters_templateWaveforms = 200*readNPY(fullfile(session.general.basePath,'clusters.templateWaveforms.npy')); % units?  % Channels sorted by amplitude 
            clusters_templateWaveformChans = readNPY(fullfile(session.general.basePath,'clusters.templateWaveformChans.npy'));   % Channel sorting
            
            spikes_amps = readNPY(fullfile(session.general.basePath,'spikes.amps.npy'));
            spikes_clusters = readNPY(fullfile(session.general.basePath,'spikes.clusters.npy'));
            spikes_depths = readNPY(fullfile(session.general.basePath,'spikes.depths.npy'));
            spikes_times = readNPY('spikes.times.npy');
            
            clusters = unique(spikes_clusters);
            for iCluster = 1:numel(clusters)
                idx = spikes_clusters == clusters(iCluster);
                spikes.times{iCluster} = spikes_times(idx);
                spikes.amplitudes{iCluster} = spikes_amps(idx);
                spikes.depths{iCluster} = spikes_depths(idx);
                spikes.total(iCluster) = sum(idx);
            end
            spikes.cluID = clusters_originalIDs';
            spikes.phy_annotation = clusters_phy_annotation';
            spikes.shankID = clusters_probes'+1;
            spikes.maxWaveformCh1 = clusters_peakChannel';
            spikes.maxWaveformCh = clusters_peakChannel'-1;
            
            spikes.filtWaveform_all = permute(num2cell(permute(clusters_templateWaveforms,[3,2,1]),[1,2]),[3,2,1])';
            spikes.probe = clusters_probes+1;
            probes = unique(clusters_probes+1);
            nChannelsPerProbe = cellfun(@numel, session.extracellular.electrodeGroups.channels);
            nChannelsPerProbe = cumsum([0,nChannelsPerProbe]);
            if any(clusters_templateWaveformChans(:) > nChannelsPerProbe(2))
                warning('loadSpikes: ALF npy data: Some waveform channels are not aligned correctly')
            end
            clusters_templateWaveformChans = rem(clusters_templateWaveformChans,nChannelsPerProbe(2));
            for i = 1:length(probes)
                clusters_templateWaveformChans(spikes.probe==probes(i),:) = clusters_templateWaveformChans(spikes.probe==probes(i),:) + nChannelsPerProbe(probes(i));
            end
            spikes.channels_all = num2cell(clusters_templateWaveformChans+1,2);
            spikes.filtWaveform = cellfun(@(X) X(1,:),spikes.filtWaveform_all,'UniformOutput', false);
            spikes.timeWaveform = cellfun(@(X) ([1:length(X)]-length(X)/2)*1000/session.extracellular.sr,spikes.filtWaveform,'UniformOutput', false);
            spikes.timeWaveform_all = spikes.timeWaveform;
            spikes.peakVoltage = cell2mat(cellfun(@(X) range(X(1,:)) ,spikes.filtWaveform_all,'UniformOutput', false))';
            spikes.maxWaveform_all = spikes.channels_all;
            
            spikesFields = fieldnames(spikes);
            badCells = clusters_phy_annotation<2;
            spikes.numcells = numel(spikes.times);
            for j = 1:numel(spikesFields)
                % Flipping dimensions on fields if necessary
                if size(spikes.(spikesFields{j})) == [spikes.numcells,1]
                    spikes.(spikesFields{j}) = spikes.(spikesFields{j})';
                end
                % Taking out bad units
                if size(spikes.(spikesFields{j})) == [1,spikes.numcells]
                    spikes.(spikesFields{j})(badCells) = [];
                end
            end
            
            % No waveforms are extracted from the raw file at this point
            spikes.processinginfo.params.WaveformsSource = 'kilosort template';
            spikes.processinginfo.params.WaveformsFiltFreq = 500;
            
        case {'nwb'} % nwb datafile
            disp('loadSpikes: Loading NWB data')
            nwb_file = fullfile(session.general.basePath,[session.general.name,'.nwb']);
            info = h5info(nwb_file);
            fieldsToExtract = {'PT_ratio','amplitude','amplitude_cutoff','cluster_id','cumulative_drift','d_prime','firing_rate','id','isi_violations','isolation_distance','l_ratio','local_index','max_drift','nn_hit_rate','nn_miss_rate', ...
                'peak_channel_id','presence_ratio','quality','recovery_slope','repolarization_slope','silhouette_score','snr','spike_amplitudes','spike_amplitudes_index','spike_times','spike_times_index','spread','velocity_above',...
                'velocity_below','waveform_duration','waveform_halfwidth','waveform_mean','waveform_mean_index'};
            
            for i = 1:numel(fieldsToExtract)
                disp(['Loading ' fieldsToExtract{i},' (',num2str(i),'/',num2str(numel(fieldsToExtract)),')'])
                if strcmp(fieldsToExtract{i},'spike_times')
                    spike_data = h5read(nwb_file,['/units/','spike_times']);
                    spike_data_index = h5read(nwb_file,['/units/','spike_times_index']);
                    spikes.total = double([spike_data_index(1);diff(spike_data_index)]);
                    index = [0;spike_data_index];
                    for j = 1:numel(spike_data_index)
                        spikes.times{j} = spike_data(index(j)+1:index(j+1));
                    end
                elseif strcmp(fieldsToExtract{i},'spike_amplitudes')
                    spike_data = h5read(nwb_file,['/units/','spike_amplitudes']);
                    spike_data_index = h5read(nwb_file,['/units/','spike_amplitudes_index']);
                    index = [0;spike_data_index];
                    for j = 1:numel(spike_data_index)
                        spikes.amplitudes{j} = spike_data(index(j)+1:index(j+1));
                    end
                elseif strcmp(fieldsToExtract{i},'waveform_mean')
                    spike_data = h5read(nwb_file,['/units/','waveform_mean']);
                    spike_data_index = h5read(nwb_file,['/units/','waveform_mean_index']);
                    index = [0;spike_data_index];
                    for j = 1:numel(spike_data_index)
                        spikes.waveform_mean{j} = spike_data(:,index(j)+1:index(j+1));
                        spikes.waveform_mean_filt{j} = spikes.waveform_mean{j};
                    end
                elseif any(strcmp(fieldsToExtract{i},{'spike_times_index','waveform_mean_index','spike_amplitudes_index'}))
                    % disp('Not imported')
                elseif strcmp(fieldsToExtract{i},'cluster_id')
                    spikes.cluID = double(h5read(nwb_file,['/units/',fieldsToExtract{i}]))';
                elseif  strcmp(fieldsToExtract{i},'amplitude')
                    spikes.peakVoltage = h5read(nwb_file,['/units/',fieldsToExtract{i}]);
                elseif strcmp(fieldsToExtract{i},'peak_channel_id')
                    % maxWaveformCh
                    electrode_channel_id = double(h5read(nwb_file,'/general/extracellular_ephys/electrodes/id'));
                    peak_channel_id = double(h5read(nwb_file,['/units/','peak_channel_id']));
                    for j = 1:numel(peak_channel_id)
                        spikes.maxWaveformCh1(j) = find(peak_channel_id(j) == electrode_channel_id);
                    end
                    spikes.maxWaveformCh = spikes.maxWaveformCh1-1;
                    spikes.peak_channel_id = peak_channel_id';
                else
                    fieldData =  h5read(nwb_file,['/units/',fieldsToExtract{i}]);
                    if isnumeric(fieldData)
                        spikes.(fieldsToExtract{i}) = fieldData';
                    else
                        spikes.(fieldsToExtract{i}) = fieldData;
                    end
                end
            end
                        
            spikes.numcells = numel(spikes.times);
            
            spikes.processinginfo.params.WaveformsSource = 'nwb';
            
            % Flipping dimensions on fields if necessary
            spikesFields = fieldnames(spikes);
            for j = 1:numel(spikesFields)
                if size(spikes.(spikesFields{j})) == [spikes.numcells,1]
                    spikes.(spikesFields{j}) = spikes.(spikesFields{j})';
                end
            end
            
        case {'allensdk'} % Allen institute's nwb data combined with info from the allenSDK
            disp('loadSpikes: Loading Allen SDK nwb data')
            nwb_file = fullfile(session.general.basePath,[session.general.name,'.nwb']);
            info = h5info(nwb_file);
            % unit_metrics = {info.Groups(7).Datasets.Name};
            fieldsToExtract = {'PT_ratio','amplitude','amplitude_cutoff','cluster_id','cumulative_drift','d_prime','firing_rate','id','isi_violations','isolation_distance','l_ratio','local_index','max_drift','nn_hit_rate','nn_miss_rate', ...
                'peak_channel_id','presence_ratio','quality','recovery_slope','repolarization_slope','silhouette_score','snr','spike_amplitudes','spike_amplitudes_index','spike_times','spike_times_index','spread','velocity_above',...
                'velocity_below','waveform_duration','waveform_halfwidth','waveform_mean','waveform_mean_index'};
            
            for i = 1:numel(fieldsToExtract)
                disp(['Loading ' fieldsToExtract{i},' (',num2str(i),'/',num2str(numel(fieldsToExtract)),')'])
                if strcmp(fieldsToExtract{i},'spike_times')
                    spike_data = h5read(nwb_file,['/units/','spike_times']);
                    spike_data_index = h5read(nwb_file,['/units/','spike_times_index']);
                    spikes.total = double([spike_data_index(1);diff(spike_data_index)]);
                    index = [0;spike_data_index];
                    for j = 1:numel(spike_data_index)
                        spikes.times{j} = spike_data(index(j)+1:index(j+1));
                    end
                elseif strcmp(fieldsToExtract{i},'spike_amplitudes')
                    spike_data = h5read(nwb_file,['/units/','spike_amplitudes']);
                    spike_data_index = h5read(nwb_file,['/units/','spike_amplitudes_index']);
                    index = [0;spike_data_index];
                    for j = 1:numel(spike_data_index)
                        spikes.amplitudes{j} = spike_data(index(j)+1:index(j+1));
                    end
                elseif strcmp(fieldsToExtract{i},'waveform_mean')
                    spike_data = h5read(nwb_file,['/units/','waveform_mean']);
                    spike_data_index = h5read(nwb_file,['/units/','waveform_mean_index']);
                    index = [0;spike_data_index];
                    for j = 1:numel(spike_data_index)
                        spikes.waveform_mean{j} = spike_data(:,index(j)+1:index(j+1));
                        spikes.waveform_mean_filt{j} = spikes.waveform_mean{j};
                    end
                elseif any(strcmp(fieldsToExtract{i},{'spike_times_index','waveform_mean_index','spike_amplitudes_index'}))
                    % disp('Not imported')
                elseif strcmp(fieldsToExtract{i},'cluster_id')
                    spikes.cluID = double(h5read(nwb_file,['/units/',fieldsToExtract{i}]))';
                elseif  strcmp(fieldsToExtract{i},'amplitude')
                    spikes.peakVoltage = h5read(nwb_file,['/units/',fieldsToExtract{i}]);
                elseif strcmp(fieldsToExtract{i},'peak_channel_id')
                    % maxWaveformCh
                    electrode_channel_id = double(h5read(nwb_file,'/general/extracellular_ephys/electrodes/id'));
                    peak_channel_id = double(h5read(nwb_file,['/units/','peak_channel_id']));
                    for j = 1:numel(peak_channel_id)
                        spikes.maxWaveformCh1(j) = find(peak_channel_id(j) == electrode_channel_id);
                    end
                    spikes.maxWaveformCh = spikes.maxWaveformCh1-1;
                    spikes.peak_channel_id = peak_channel_id';
                else
                    fieldData =  h5read(nwb_file,['/units/',fieldsToExtract{i}]);
                    if isnumeric(fieldData)
                        spikes.(fieldsToExtract{i}) = fieldData';
                    else
                        spikes.(fieldsToExtract{i}) = fieldData;
                    end
                end
            end
            
            % Getting raw timestamps using the AllenSDK saved as separate npy files for each unit
            k = 0;
            for iCells = 1:numel(spikes.times)
                spikes.shankID(iCells) = find(cellfun(@(X) ismember(spikes.maxWaveformCh1(iCells),X),session.extracellular.electrodeGroups.channels));
                rawTimestampsFile = fullfile(session.analysisTags.rawTimestampsFile, [num2str(spikes.id(iCells)),'.npy']);
                if exist(rawTimestampsFile,'file')
                    temp = readNPY(rawTimestampsFile);
                    spikes.ts{iCells} = double(temp);
                    k = k + 1;
                else
                    spikes.ts{iCells} = [];
                end
            end

            % Removing empty units from structure
            unitsToRemove = find(cellfun(@isempty,spikes.ts));
            fieldsToProcess = fieldnames(spikes);
            fieldsToProcess = fieldsToProcess(structfun(@(X) (isnumeric(X) || iscell(X)) && numel(X)==numel(spikes.times),spikes));
            for iField = 1:numel(fieldsToProcess)   
                spikes.(fieldsToProcess{iField})(unitsToRemove) = [];
            end
            
            % Getting raw waveforms
            unitsToProcess = {};
            channel_offset = [];
            for iProbe = 1:session.extracellular.nElectrodeGroups
                unitsToProcess{iProbe} = find(spikes.shankID == iProbe);
                session1{iProbe} = session;
                session1{iProbe}.extracellular.fileName = fullfile(session.extracellular.electrodeGroups.label{iProbe},'spike_band.dat');
                session1{iProbe}.extracellular.nChannels = length(session.extracellular.electrodeGroups.channels{iProbe});
                session1{iProbe}.extracellular.electrodeGroups.channels = {1:session1{iProbe}.extracellular.nChannels};
                session1{iProbe}.extracellular.nElectrodeGroups = 1;
                channel_offset(iProbe) = numel([session.extracellular.electrodeGroups.channels{1:iProbe}]) - numel([session.extracellular.electrodeGroups.channels{1}]);
                session1{iProbe}.channelTags.Bad.channels = session.channelTags.Bad.channels(ismember(session1{iProbe}.channelTags.Bad.channels,session.extracellular.electrodeGroups.channels{iProbe})) - channel_offset(iProbe);
                session1{iProbe} = getBadChannelsFromDat(session1{iProbe},'extraLabel', ['probe #' num2str(iProbe)]);
                session.channelTags.Bad.channels = unique([session.channelTags.Bad.channels,session1{iProbe}.channelTags.Bad.channels + channel_offset(iProbe)]);
            end
            disp(['Applying channel offset: ', num2str(channel_offset),' (diff: ' , num2str(diff(channel_offset)),')'])
            
            % Pulling waveforms (in parfor if possible)
            parallel_toolbox_installed = isToolboxInstalled('Parallel Computing Toolbox'); % Validating that Parallel Computing Toolbox has been installed
            spikes_out = {}; tic;
            probesToProcess = sort(find(~cellfun(@isempty, unitsToProcess)));
            if parallel_toolbox_installed
                disp('Extracting waveforms from parfor loop')
                gcp; 
                parfor iProbe = 1:numel(probesToProcess)
                    disp(['Getting waveforms from ',num2str(numel(unitsToProcess{probesToProcess(iProbe)})) ,' cells from binary file (',num2str(probesToProcess(iProbe)),'/',num2str(session.extracellular.nElectrodeGroups),')'])
                    spikes_out{iProbe} = getWaveformsFromDat(spikes,session1{probesToProcess(iProbe)},'unitsToProcess',unitsToProcess{probesToProcess(iProbe)},'saveFig', true,'extraLabel', ['probe #' num2str(iProbe)]);
                end
            else
                disp('Extracting waveforms')
                for iProbe = 1:numel(probesToProcess)
                    disp(['Getting waveforms from ',num2str(numel(unitsToProcess{probesToProcess(iProbe)})) ,' cells from binary file (',num2str(probesToProcess(iProbe)),'/',num2str(session.extracellular.nElectrodeGroups),')'])
                    spikes_out{iProbe} = getWaveformsFromDat(spikes,session1{probesToProcess(iProbe)},'unitsToProcess',unitsToProcess{probesToProcess(iProbe)},'saveFig', true,'extraLabel', ['probe #' num2str(iProbe)]);
                end
            end
            
            % Writing fields back to spikes struct
            fieldsWaveform = {'maxWaveformCh','maxWaveformCh1','rawWaveform','filtWaveform','rawWaveform_all','rawWaveform_std','filtWaveform_all','filtWaveform_std','timeWaveform','timeWaveform_all','peakVoltage','channels_all','peakVoltage_sorted','maxWaveform_all','peakVoltage_expFitLengthConstant'};
            for i = 1:numel(probesToProcess)
                iProbe = probesToProcess(i);
                for jFields = 1:numel(fieldsWaveform)
                    spikes.(fieldsWaveform{jFields})(unitsToProcess{iProbe}) = spikes_out{i}.(fieldsWaveform{jFields})(unitsToProcess{iProbe});
                end
                spikes.maxWaveformCh1(unitsToProcess{iProbe}) = spikes.maxWaveformCh1(unitsToProcess{iProbe}) + channel_offset(iProbe);
                spikes.maxWaveformCh(unitsToProcess{iProbe}) = spikes.maxWaveformCh(unitsToProcess{iProbe}) + channel_offset(iProbe);
                for j = 1:length(unitsToProcess{iProbe})
                    spikes.channels_all{unitsToProcess{iProbe}(j)} = spikes.channels_all{unitsToProcess{iProbe}(j)} + channel_offset(iProbe);
                end
            end
            fieldsParams = {'WaveformsSource','WaveformsFiltFreq','Waveforms_nPull','WaveformsWin_sec','WaveformsWinKeep','WaveformsFilterType'};
            for jFields = 1:numel(fieldsParams)
                spikes.processinginfo.params.(fieldsParams{jFields}) = spikes_out{end}.processinginfo.params.(fieldsParams{jFields});
            end
            toc
            spikes.numcells = numel(spikes.times);
            
            % Flipping dimensions on fields if necessary
            spikesFields = fieldnames(spikes);
            for j = 1:numel(spikesFields)
                if size(spikes.(spikesFields{j})) == [spikes.numcells,1]
                    spikes.(spikesFields{j}) = spikes.(spikesFields{j})';
                end
            end
        case {'mclust'} % MClust developed by David Redish
            disp('loadSpikes: Loading MClust data')
            UID = 0;
            fileList = dir(fullfile(clusteringpath_full,'TT*.mat'));
            fileList = {fileList.name};
            fileList(contains(fileList,'_')) = [];
            if exist(fullfile(clusteringpath_full,'timestamps.npy'),'file')
                % This is specific for open ephys system where time zero does not occur with the recording start
                % The timestamps.npy must be located with the spike sorted data
                open_ephys_timestamps = readNPY(fullfile(clusteringpath_full,'timestamps.npy'));
            end
            for iTetrode = 1:numel(fileList)
                disp(['Loading tetrode ' num2str(iTetrode) '/' num2str(numel(fileList)) ])
                tetrodeData = load(fullfile(clusteringpath_full,fileList{iTetrode}));
                if exist(fullfile(clusteringpath_full,[fileList{iTetrode}(1:end-4),'.clusters']),'file')
                    clusterData = load(fullfile(clusteringpath_full,[fileList{iTetrode}(1:end-4),'.clusters']),'-mat');
                    timeStampData = load(fullfile(clusteringpath_full,[fileList{iTetrode}(1:end-4),'_Time.fd']),'-mat');
                    energyData = load(fullfile(clusteringpath_full,[fileList{iTetrode}(1:end-4),'_Energy.fd']),'-mat');
                    amplitudeData = load(fullfile(clusteringpath_full,[fileList{iTetrode}(1:end-4),'_Amplitude.fd']),'-mat');
                    
                    for i = 1:numel(clusterData.MClust_Clusters)
                        UID = UID +1;
                        if exist('open_ephys_timestamps','var')
                            % Again, specific to open ephys
                            spikes.ts{UID} = round(tetrodeData.TimeStamps(clusterData.MClust_Clusters{i}.myPoints)*session.extracellular.sr)-double(open_ephys_timestamps(1));
                        end
                        spikes.times{UID} = tetrodeData.TimeStamps(clusterData.MClust_Clusters{i}.myPoints);
                        spikes.shankID(UID) = iTetrode;
                        spikes.cluID(UID) = i;
                        spikes.total(UID) = length(spikes.times{UID});
                        spikes.filtWaveform_all{UID} = permute(mean(tetrodeData.WaveForms(clusterData.MClust_Clusters{i}.myPoints,:,:)),[3,2,1])';
                        spikes.channels_all{UID} = session.extracellular.electrodeGroups.channels{iTetrode};
                        [~,index1] = max(max(spikes.filtWaveform_all{UID}') - min(spikes.filtWaveform_all{UID}'));
                        spikes.maxWaveformCh(UID) = session.extracellular.electrodeGroups.channels{iTetrode}(index1)-1; % index 0;
                        spikes.maxWaveformCh1(UID) = session.extracellular.electrodeGroups.channels{iTetrode}(index1); % index 1;
                        spikes.filtWaveform{UID} = spikes.filtWaveform_all{UID}(index1,:);
                        spikes.peakVoltage(UID) = max(spikes.filtWaveform{UID}) - min(spikes.filtWaveform{UID});
                        
                        % Incorporating extra fields from MClust from the channel with largest amplitude
                        spikes.energy{UID} = energyData.FeatureData(clusterData.MClust_Clusters{i}.myPoints,index1);
                        spikes.amplitude{UID} = amplitudeData.FeatureData(clusterData.MClust_Clusters{i}.myPoints,index1);
                    end
                end
            end
            spikes.processinginfo.params.WaveformsSource = 'spk files';
            
        case {'klustakwik', 'neurosuite'}
            disp('loadSpikes: Loading Klustakwik data')
            UID = 0;
            electrodeGroups_detected = [];
            if isnan(electrodeGroups)
                fileList = dir(fullfile(clusteringpath_full,[basename,'.res.*']));
                fileList = {fileList.name};
                for i = 1:length(fileList)
                    temp = strsplit(fileList{i},'.res.');
                    electrodeGroups_detected = [electrodeGroups_detected,str2double(temp{2})];
                end
                electrodeGroups = sort(electrodeGroups_detected);
            end

            for k = 1:length(electrodeGroups)
                electrodeGroup = electrodeGroups(k);
                if ~exist(fullfile(clusteringpath_full, [basename '.clu.' num2str(electrodeGroup)]),'file'),
                    disp(['.clu.' num2str(electrodeGroup) ' file not found. Skipping electrode group #' num2str(electrodeGroup) '/' num2str(length(electrodeGroups))])
                    continue;
                end
                disp(['Loading electrode group #' num2str(electrodeGroup) '/' num2str(length(electrodeGroups)) ])
                if ~raw_clusters
                    cluster_index = load(fullfile(clusteringpath_full, [basename '.clu.' num2str(electrodeGroup)]));
                    time_stamps = load(fullfile(clusteringpath_full,[basename '.res.' num2str(electrodeGroup)]));
                    if parameters.getWaveformsFromSource
                        fname = fullfile(clusteringpath_full,[basename '.spk.' num2str(electrodeGroup)]);
                        f = fopen(fname,'r');
                        waveforms = LSB * double(fread(f,'int16'));
                        samples = size(waveforms,1)/size(time_stamps,1);
                        electrodes = numel(session.extracellular.electrodeGroups.channels{electrodeGroup});
                        waveforms = reshape(waveforms, [electrodes,samples/electrodes,length(waveforms)/samples]);
                    end
                else
                    cluster_index = load(fullfile(clusteringpath_full, 'OriginalClus', [basename '.clu.' num2str(electrodeGroup)]));
                    time_stamps = load(fullfile(clusteringpath_full, 'OriginalClus', [basename '.res.' num2str(electrodeGroup)]));
                end
                cluster_index = cluster_index(2:end);
                nb_clusters = unique(cluster_index);
                nb_clusters2 = nb_clusters(nb_clusters > 1);
                
                tol_samples = session.extracellular.sr*5e-4; % 0.5 ms tolerance in timestamp units
                for i = 1:length(nb_clusters2)
                    UID = UID +1;
                    spikes.ts{UID} = time_stamps(cluster_index == nb_clusters2(i));
                    [spikes.ts{UID},~] = uniquetol(spikes.ts{UID},tol_samples,'DataScale',1); % unique values within tol (<= 0.8ms)
                    spikes.times{UID} = spikes.ts{UID}/session.extracellular.sr;
                    spikes.shankID(UID) = electrodeGroup;
                    spikes.hexatrode(UID) = electrodeGroup;
                    spikes.cluID(UID) = nb_clusters2(i);
                    spikes.cluster_index(UID) = nb_clusters2(i);
                    spikes.total(UID) = length(spikes.ts{UID});
                    if parameters.getWaveformsFromSource
                        spikes.filtWaveform_all{UID} = mean(waveforms(:,:,cluster_index == nb_clusters2(i)),3);
                        spikes.filtWaveform_all_std{UID} = permute(std(permute(waveforms(:,:,cluster_index == nb_clusters2(i)),[3,1,2])),[2,3,1]);
                        [~,index1] = max(max(spikes.filtWaveform_all{UID}') - min(spikes.filtWaveform_all{UID}'));
                        spikes.maxWaveformCh(UID) = session.extracellular.electrodeGroups.channels{electrodeGroup}(index1)-1; % index 0;
                        spikes.maxWaveformCh1(UID) = session.extracellular.electrodeGroups.channels{electrodeGroup}(index1); % index 1;
                        spikes.filtWaveform{UID} = spikes.filtWaveform_all{UID}(index1,:);
%                         spikes.filtWaveform_std{unit_nb} = spikes.filtWaveform_all_std{unit_nb}(index1,:);
                        spikes.peakVoltage(UID) = max(spikes.filtWaveform{UID}) - min(spikes.filtWaveform{UID});
                    end
                end
                if parameters.getWaveformsFromDat
                    spikes.processinginfo.params.WaveformsSource = 'spk files';
                end
            end
            clear cluster_index time_stamps
            
        case {'klustaviewa','klustasuite'} % Loading klustaViewa - Kwik format (Klustasuite 0.3.0.beta4)
            disp('loadSpikes: Loading KlustaViewa data')
            kwik_file = fullfile(clusteringpath_full, [basename, '.kwik']);
            kwx_file = fullfile(clusteringpath_full, [basename, '.kwx']);
            UID = 1;
            
            if isnan(electrodeGroups)
                kwik_hdf5info = hdf5info(kwik_file);
                nElectrodeGroups = length(kwik_hdf5info.GroupHierarchy.Groups(2).Groups);
                electrodeGroups = 1:nElectrodeGroups;
            end
            for k = 1:length(electrodeGroups)
                electrodeGroup = electrodeGroups(k);
                spike_times   = double(hdf5read(kwik_file, ['/channel_groups/' num2str(electrodeGroup-1) '/spikes/time_samples']));
                recording_nb  = double(hdf5read(kwik_file, ['/channel_groups/' num2str(electrodeGroup-1) '/spikes/recording']));
                cluster_index = double(hdf5read(kwik_file, ['/channel_groups/' num2str(electrodeGroup-1) '/spikes/clusters/main']));
                if exist(fullfile(clusteringpath_full, [basename, '.kwx']),'file')
                    waveforms = double(hdf5read(kwik_file, ['/channel_groups/' num2str(electrodeGroup-1) '/waveforms_filtered']));
                end
                clusters = unique(cluster_index);
                tol_samples = session.extracellular.sr*5e-4; % 0.5 ms tolerance in timestamp units
                for i = 1:length(clusters(:))
                    cluster_type = double(hdf5read(kwik_file, ['/channel_groups/' num2str(electrodeGroup-1) '/clusters/main/' num2str(clusters(i)),'/'],'cluster_group'));
                    if cluster_type == 2
                        indexes{UID} = UID*ones(sum(cluster_index == clusters(i)),1);
                        spikes.ts{UID} = spike_times(cluster_index == clusters(i))+recording_nb(cluster_index == clusters(i))*40*40000;
                        [spikes.ts{UID},~] = uniquetol(spikes.ts{UID},tol_samples,'DataScale',1); % unique values within tol (<= 0.8ms)
                        spikes.times{UID} = spikes.ts{UID}/session.extracellular.sr;
                        spikes.total(UID) = sum(cluster_index == clusters(i));
                        spikes.shankID(UID) = electrodeGroup;
                        spikes.cluID(UID) = clusters(i);
                        if exist(kwx_file,'file')
                            spikes.filtWaveform_all{UID} = mean(waveforms(:,:,cluster_index == clusters(i)),3);
                            spikes.filtWaveform_all_std{UID} = permute(std(permute(waveforms(:,:,cluster_index == clusters(i)),[3,1,2])),[2,3,1]);
                        end
                        UID = UID+1;
                    end
                end
            end
            
            % Loading sebastienroyer's data format
        case {'sebastienroyer'}
            temp = load(fullfile(clusteringpath_full,[basename,'.mat']));
            cluster_index = temp.spk.g;
            cluster_timestamps = temp.spk.t;
            clusters = unique(cluster_index);
            for i = 1:length(clusters)
                spikes.ts{i} = cluster_timestamps(find(cluster_index == clusters(i)));
                spikes.times{i} = spikes.ts{i}/session.extracellular.sr;
                spikes.total(i) = length(spikes.times{i});
                spikes.cluID(i) = clusters(i);
                spikes.filtWaveform_all{i}  = temp.spkinfo.waveform(:,:,i);
            end
            
        case {'kilosort'}
            disp('loadSpikes: Loading KiloSort data (the rez.mat file)')
            if exist(fullfile(clusteringpath_full, 'rez.mat'),'file')
                load(fullfile(clusteringpath_full, 'rez.mat'))
%                 temp = find(rez.connected);
%                 peak_channel = temp(peak_channel);
%                 clear temp
            else
                error('rez.mat file does not exist')
            end
            
            if size(rez.st3,2)>4
                spikeClusters = uint32(1+rez.st3(:,5));
                spike_cluster_index = uint32(spikeClusters-1); % -1 for zero indexing
            else
                spikeTemplates = uint32(rez.st3(:,2));
                spike_cluster_index = uint32(spikeTemplates-1); % -1 for zero indexing
            end
            
            spike_times = uint64(rez.st3(:,1));
            spike_amplitudes = rez.st3(:,3);
            spike_clusters = unique(spike_cluster_index);

            UID = 1;
            tol_ms = session.extracellular.sr/1100; % 1 ms tolerance in timestamp units
            for i = 1:length(spike_clusters)
                spikes.ids{UID} = find(spike_cluster_index == spike_clusters(i));
                tol = tol_ms/max(double(spike_times(spikes.ids{UID}))); % unique values within tol (=within 1 ms)
                [spikes.ts{UID},ind_unique] = uniquetol(double(spike_times(spikes.ids{UID})),tol);
                spikes.ids{UID} = spikes.ids{UID}(ind_unique);
                spikes.times{UID} = spikes.ts{UID}/session.extracellular.sr;
                spikes.cluID(UID) = spike_clusters(i);
                spikes.total(UID) = length(spikes.ts{UID});
                spikes.amplitudes{UID} = double(spike_amplitudes(spikes.ids{UID}));
                [~,spikes.maxWaveformCh1(UID)] = max(abs(rez.U(:,rez.iNeigh(1,spike_clusters(i)),1)));
                UID = UID+1;
            end
            
        case {'wave_clus'}
            UID = 1;
            fileList = dir(fullfile(clusteringpath_full,'times_*.mat'));
            fileList = {fileList.name};
            for i = 1:numel(fileList)
                spike_data = load(fileList{i});
                spikes.sr = spike_data.par.sr;
                clusters = unique(spike_data.cluster_class(:,1));
                clusters = clusters(clusters>0);
                for j = 1:numel(clusters)
                    idx = spike_data.cluster_class(:,1) == clusters(j);
                    spikes.times{UID} = spike_data.cluster_class(idx,2)/1000;
                    spikes.total(UID) = length(spikes.times{UID});
                    spikes.cluID(UID) = clusters(j);
                    spikes.filtWaveform{UID} = mean(spike_data.spikes(idx,:));
                    spikes.filtWaveform_std{UID} = std(spike_data.spikes(idx,:));
                    spikes.timeWaveform{UID} = -1000*spike_data.par.w_pre/spikes.sr+1000/spikes.sr:1000/spikes.sr:spike_data.par.w_post/spikes.sr*1000;
                    spikes.peakVoltage(UID) = range(spikes.filtWaveform{UID}); % UNITS ?
                    spikes.maxWaveformCh1(UID) = i;
                    spikes.maxWaveformCh(UID) = i-1;
                    spikes.shankID(UID) = 1;
                    UID = UID + 1;
                end
            end
            
        case {'spyking circus'}
            disp('loadSpikes: Loading SpyKING CIRCUS data')
            % Required file: basename.result.hdf5
            % Extracts spike times and amplitudes
            
            nwb_file1 = fullfile(clusteringpath_full,[basename '.result-merged.hdf5']);
            nwb_file2 = fullfile(clusteringpath_full,[basename '.result.hdf5']);
            if exist(nwb_file1,'file')
                nwb_file = nwb_file1;
            else
                nwb_file = nwb_file2;
            end
            info = h5info(nwb_file);
            template_names = {info.Groups(1).Datasets.Name};
            nCells = numel(template_names);
            for i = 1:nCells
                spikes_times = h5read(nwb_file,['/spiketimes/',template_names{i}]);
                spikes.times{i} = double(spikes_times(1,:)')/session.extracellular.sr;
                amplitudes = h5read(nwb_file,['/amplitudes/',template_names{i}]);
                spikes.amplitudes{i} = double(amplitudes(1,:)');
                spikes.cluID(i) = i;
                spikes.total(i) = length(spikes.times{i});
            end
        case {'mountainsort'}
            error('mountainsort output format not implemented yet')
        case {'ironclust'}
            error('ironclust output format not implemented yet')
        otherwise
            error('Please provide a compatible clustering format')
    end
    spikes.basename = basename;
    spikes.numcells = numel(spikes.times);
    spikes.UID = 1:spikes.numcells;
    spikes.sr = session.extracellular.sr;
    
    % Getting waveforms from dat (raw data)
    if parameters.getWaveformsFromDat && ~strcmpi(format,'allensdk')
        spikes = getWaveformsFromDat(spikes,session,'showWaveforms',parameters.showWaveforms,'saveMat', parameters.saveMat);
    end
    
    % Attaching info about how the spikes structure was generated
    spikes.processinginfo.function = 'loadSpikes';
    spikes.processinginfo.version = 4.3;
    spikes.processinginfo.date = now;
    spikes.processinginfo.params.forceReload = parameters.forceReload;
    spikes.processinginfo.params.electrodeGroups = electrodeGroups;
    spikes.processinginfo.params.raw_clusters = raw_clusters;
    spikes.processinginfo.params.getWaveformsFromDat = parameters.getWaveformsFromDat;
    spikes.processinginfo.params.basename = basename;
    spikes.processinginfo.params.format = format;
    spikes.processinginfo.params.clusteringpath = clusteringpath;
    spikes.processinginfo.params.basepath = basepath;
    spikes.processinginfo.params.getWaveformsFromSource = parameters.getWaveformsFromSource;
    try
        spikes.processinginfo.username = char(java.lang.System.getProperty('user.name'));
        spikes.processinginfo.hostname = char(java.net.InetAddress.getLocalHost.getHostName);
    catch
        disp('Failed to retrieve system info.')
    end
    
    % Saving output to a CellExplorer compatible spikes file.
    if parameters.saveMat
        disp('loadSpikes: Saving spikes')
        try
            structSize = whos('spikes');
            if structSize.bytes/1000000000 > 2
                save(fullfile(basepath,[basename,'.spikes.cellinfo.mat']),'spikes','-v7.3')
            else
                save(fullfile(basepath,[basename,'.spikes.cellinfo.mat']),'spikes')
            end
        catch
            warning('Spikes could not be saved')
        end
    end
end

filteredFields = {'UID','shankID','cluID','region'};
for i = 1:numel(filteredFields)
    if ~isempty(parameters.(filteredFields{i}))
        if isfield(spikes, filteredFields{i})
            toRemove = ~ismember(spikes.(filteredFields{i}),parameters.(filteredFields{i}));
            
            spikes = removeCells(toRemove,spikes);
        else
            warning(['The filtered field does not exist in the spikes struct: ' filteredFields{i}])
        end
    end
end


end

function spikes = removeCells(UIDsToRemove,spikes)
    % Function to remove cells from the structure. toRemove is the INDEX of the UID in spikes.UID
    % Functionaloty taken from Buzcode but altered to include all fields.
    
    fields2clean = fieldnames(spikes);
    for i = 1:numel(fields2clean)
        if (iscell(spikes.(fields2clean{i})) || isnumeric(spikes.(fields2clean{i}))) && numel(spikes.(fields2clean{i})) == spikes.numcells
            % Cleaning only cell array- and numeric fields
            spikes.(fields2clean{i})(UIDsToRemove) = [];
        end
    end 
    if ~isfield(spikes,'numcells_orig')
        spikes.numcells_orig = spikes.numcells;
    end
    spikes.numcells = sum(~UIDsToRemove);
end
