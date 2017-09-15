function spikes = ss_detect(data, spikes)
% UltraMegaSort2000 by Hill DN, Mehta SB, & Kleinfeld D  - 07/12/2010
%
% ss_detect - Detection of spikes in multi-channel data over multiple trials
%
% Usage:
%      spikes = ss_detect( data, spikes )
%
% Description:
%     SPIKES = SS_DETECT_SPIKES(data, params) takes a matrix of data
%     and returns a spikes object containing the waveforms and spike times
%     embedded in that signal.  This is determined by observing threshold
%     crossings on all channels.  The threshold can be determined in "auto"
%     mode (see below) where the user simply specifies how many standard
%     deviations should be used for threshold, or in "manual" mode where
%     the actual value is used.  All threshold crossings on any channel are
%     events as long as they are not preceeded too closely be another
%     event.  See SPIKES.PARAMS.SHADOW below.
%
%     NOTE: it is assumed that the data has been previously filtered and
%     that there is no voltage offset to the signal so that the mean signal
%      is 0.
%
%     Input data can either be in a matrix format [trials X samples X
%     channels] or as a cell {trials}[samples x channels]. If a data set is
%     too large to fit in memory, ss_detect can be called multiple times
%     with different data sets.  The new spikes will be appended to the
%     data for the previously detected spikes.  However, the threshold for
%     spike detection will always be the one calculated from the first data
%     set.
%
%     This function saves a window of data samples from each channel for
%     each detected event.  This window is determined by parameters in
%     spikes.params and described below.  In brief, the user specifies
%     (1) how long a window to extract, (2) where in the window the
%     threshold crossing shuld appear, and (3) a minimum separation time
%     between detected events.
%
%     The function places the following fields in the spikes object:
%       SPIKES.WAVEFORMS : [events X SAMPLES X CHANNELS] matrix of event waveforms
%       SPIKES.TRIALS:  array containing which trial the event was observed
%       SPIKES.SPIKETIMES: array containing time within trial of each event
%       SPIKES.UNWRAPPED_TIMES: array of time within experiments (assumes a short, specified delay between trials)
%       SPIKES.INFO.DETECT: structure containing information on detect session - see manual for more details
%
%  Extensions:
%      While this function assumes a simple voltage threshold, the user may
% write their own spike detection function.  The SPIKES structure should be
% compatible with the rest of the spike sorting toolbox as long as all
% fields listed above are set.  Also, a function handle should be
% placed into spikes.params.detect_method as described in undetectd.m
%
%   (1) The spikes object is
%
%  Inputs:
%     data  -- matrix of data {trials}[ samples X channels ]
%
%     spikes -- should contain 1 field "params"
%
%     "params" is a parameter structure that should contain the following
%        fields:
%           params.Fs       -- sampling rate of signal (Hz)
%
%           params.detect_method -- determines interpretation of thresh
%                       "auto" ==> thresh is how many standard deviations
%                       to set the threshold below 0
%                        "manual" ==> thresh is actual threshold to use
%
%           params.thresh   -- threshold for spike detection
%                           -- note that in manual mode, a threshold must be
%                              specified as an array giving a value for each
%                              channel but in auto mode, only 1 number should
%                              be given
%
%           params.window_size -- length of data to extract for
%                                   each spike (ms)
%
%           params.shadow   -- minimum spacing between spikes (ms)
%
%           params.cross_time  -- time of threshold crossing to use in
%                               each spike window (ms)
%
%
%   OUTPUT:
%           spikes --  a spike data structure containing time and data
%                   window for each spike
%
%           thresh  -- the actual threshold value used
%


% if the input is not a cell, convert it to one
if ~iscell(data)
    data = num2cell( data, [2 3] );
    data = cellfun(@squeeze,data,'UniformOutput',false);
end

append = isfield(spikes, 'waveforms');

% determine which trial we are on if appending
if append
    pre_trials = length(spikes.info.detect.dur);
else
    pre_trials = 0;
end

% set some constants
params = spikes.params;
num_trials     = length(data);
num_channels   = size(data{1}, 2);
window_samples = round(params.Fs * params.detect.window_size / 1000);
shadow         = round(params.Fs * params.detect.shadow      / 1000);
samples_before = round(params.Fs * params.detect.cross_time  / 1000);
samples_after  = round(params.Fs * params.detect.max_jitter  / 1000) + window_samples - (1 + samples_before);
jitter_range   = samples_before - 1 + (1:round(spikes.params.detect.max_jitter * spikes.params.Fs / 1000));

% determine threshold

spikes.info.detect.cov = get_covs(data, window_samples);

thresh  = zeros(num_trials,num_channels);
stds    = zeros(num_trials,num_channels);

for j = 1:num_trials
    stdev     = std(data{j});
    stds(j,:) = stdev;
    if     isequal(spikes.params.detect.method, 'auto')
        thresh(j,:) = -params.detect.thresh * stdev;
    elseif isequal(spikes.params.detect.method, 'manual')
        thresh(j,:) =  params.detect.thresh;
    elseif isequal(spikes.params.detect.method, 'mad') % maximum absolute deviation
        thresh(j,:) = -params.detect.thresh * (median(abs(data{j})) / 0.6745);
    else
        error('Unknown spike detection method.')
    end
end

spikes.info.detect.stds   = mean(stds,1);
spikes.info.detect.thresh = mean(thresh,1);

% find all threshold crossings
if ~append
    spikes.waveforms  = [];
    spikes.spiketimes = [];
    spikes.trials     = [];
    spikes.info.detect.event_channel = [];
end

for j = 1:num_trials
    
    % get crossings on all channels for this trial
    crossings = zeros(num_channels,size(data{j},1)-1);
    for k = 1:num_channels
        crossings(k,:) = (data{j}(1:end-1,k) > thresh(j,k) & data{j}(2:end,k) <= thresh(j,k))';
    end
    
    cross_num = sum(crossings);
    crossings = find(sum(crossings));
        
    % remove bad crossings
    crossings(1 + find(diff(crossings) <= shadow)) = [];
    crossings(crossings <= samples_before) = [];
    crossings(crossings > size(data{j},1) - samples_after) = [];
    
    spikes.nlength = single(cross_num(crossings));        
    
    % update spiketimes, trials, and waveforms
    spikes.spiketimes = [spikes.spiketimes crossings / params.Fs];
    spikes.trials     = [spikes.trials pre_trials + (j * ones([1 length(crossings)]))];
    w = zeros([length(crossings), samples_before + 1 + samples_after, num_channels], 'single');
    
    for k = 1:length(crossings) % use bsxfun here for speed-up
        indices  = crossings(k) + (-samples_before:samples_after);
        w(k,:,:) = data{j}(indices, :);
    end
    spikes.waveforms = [spikes.waveforms; w];
    
    spikes.info.detect.dur(j + pre_trials) = size(data{j}, 1) / params.Fs;
end

clear data

% find spike amplitudes

% save everything
spikes.waveforms       = single(spikes.waveforms);
spikes.spiketimes      = single(spikes.spiketimes);
spikes.trials          = single(spikes.trials);
spikes.unwrapped_times = single(unwrap_time(spikes.spiketimes, spikes.trials, spikes.info.detect.dur, spikes.params.display.trial_spacing));

% identify which channel the event occurred on
divisor = repmat(spikes.info.detect.thresh, [size(spikes.waveforms,1) 1]);
[~, spikes.info.detect.event_channel] = max(squeeze(min(spikes.waveforms(:,jitter_range,:), [], 2))./divisor, [], 2);
spikes.info.detect.event_channel = single(spikes.info.detect.event_channel);

% save some more data that will be useful later
spikes.info.detect.align_sample = samples_before + 1;
[pca.u,pca.s,pca.v] = svd(detrend(spikes.waveforms(:,:),'constant'), 0); % SVD the data matrix
spikes.info.pca = pca;

% report detection rate
detect_rate = length(spikes.spiketimes) / sum(spikes.info.detect.dur);
disp( ['Detected on average ' num2str(detect_rate) ' events per second of data '] );

% get covariance matrix of background nosie by randomly sampling 10000 timepoints
function c = get_covs(data, samples)

num_trials   = length(data);
num_channels = size(data{1},2);
num_samples  = zeros(1,num_trials);

for j = 1:num_trials, num_samples(j) = size(data{j},1); end

max_samples = 10000;
waves       = zeros([max_samples samples num_channels]);
tr_index    = ceil(num_trials * rand([1 max_samples]));
data_index  = ceil((num_samples(tr_index)-samples) .* rand([1 max_samples]));

for j = 1:max_samples
    waves(j,:,:) = data{tr_index(j)}(data_index(j) + (0:samples-1),:);
end

c = cov(waves(:,:));