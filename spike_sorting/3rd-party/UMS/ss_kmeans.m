function spikes = ss_kmeans(spikes, options)
% UltraMegaSort2000 by Hill DN, Mehta SB, & Kleinfeld D  - 07/12/2010
%
% ss_kmeans - K-means clustering.
%
% Usage:
%       spikes = ss_kmeans(spikes, options)
%
% Description:
%     Performs k-means clustering on the (M x N) matrix SPIKES.WAVEFORMS and stores the
%     resulting group assignments in SPIKES.INFO.KMEANS.ASSIGNS, the cluster
%     centroids in SPIKES.INFO.KMEANS.CENTROIDS, and the mean squared error in
%     SPIKES.INFO.KMEANS.MSE.  The W, B, and T matrices (within-cluster, between-
%     cluster, and total) covariance matrices are in SPIKES.INFO.KMEANS.W, etc.
%
%     K-means algorithm is an EM algorithm that finds K cluster centers in
%     N-dimensional space and assigns each of the M data vectors to one of these
%     K points.  The process is iterative: new cluster centers are calculated as
%     the mean of their previously assigned vectors and vectors are then each
%     reassigned to their closest cluster center.  This finds a local minimum for
%     the mean squared distance from each point to its cluster center; this is
%     also a (local) MLE for the model of K isotropic gaussian clusters.
%
%     This method is highly outlier sensitive; MLE is not robust to the addition
%     of a few waveforms that are not like the others and will shift the 'true'
%     cluster centers (or add new ones) to account for these points.  See
%     SS_OUTLIERS for one solution.
%
%     The algorithm used here speeds convergence by first solving for 2 means,
%     then using these means (slightly jittered) as starting points for a 4-means
%     solution.  This continues for log2(K) steps until K-means have been found.
%     Clusters of size one are not allowed and are lumped into the nearest
%     non-singleton cluster, with the result that occasionally fewer than K
%     clusters will actually be returned.
%
%     SPIKES = SS_KMEANS(SPIKES, OPTIONS) allows specification of clustering
%     parameters.  OPTIONS is a structure with some/all of the following fields
%     defined.  (Any OPTIONS fields left undefined (or all fields if no OPTIONS
%     structure is passed in) uses its default value.)
%
%         OPTIONS.DIVISIONS (default: round(log2(M/400)), restricted to be between
%               4 and 7) sets the desired number of clusters to 2^DIVISIONS.  The
%               actual number of clusters may be less than this number of singleton
%               clusters are encountered.
%         OPTIONS.REPS (default: 1) specifies the number of runs of the full
%               k-means solution.  The function will return the assignments that
%               resulted in the minimum MSE.
%         OPTIONS.REASSIGN_CONVERGE (default: 0) defines a convergence condition
%               by specifying the max number of vectors allowed to be reassigned
%               in an EM step.  If <= this number of vectors is reassigned, the
%               this condition is met.
%         OPTIONS.MSE_CONVERGE (default: 0) defines a second convergence condition.
%               If the fractional change in mean squared error from one iteration
%               to the next is smaller than this value, this condition is met.
%
%     NOTE: Iteration stops when either of the convergence conditions is met.
%
% References:
%     Duda RO et al (2001).  _Pattern Classification_, Wiley-Interscience
%
% Major edits made by Terence Brouns (2017).

% Undocumented option: OPTIONS.PROGRESS (default: 1) determines whether the progress
%                                 bar is displayed during the clustering.
%
% 

%% ARGUMENT CHECKING
if (~isfield(spikes, 'waveforms') || (size(spikes.waveforms, 1) < 1))
    error('SS:waveforms_undefined', 'The SS object does not contain any waveforms!');
end

%% CONSTANTS
d     = diag(spikes.info.pca.s);
r     = find(cumsum(d) / sum(d) > 0.95, 1);
waves = spikes.waveforms(:,:) * spikes.info.pca.v(:,1:r);

[M,N]              = size(waves);
target_clustersize = spikes.info.dur * spikes.params.kmeans_clustersize;
jitter             = meandist_estim(waves) / 100 / N;        % heuristic

%% DEFAULTS
opts.divisions         = round(log2(M / target_clustersize)); % power of 2 that gives closest to target_clustersize, but in [4..7]
opts.divisions         = max(min(opts.divisions, 7), 4);      % restrict to 16-128 clusters; heuristic.
opts.reps              = 1;                                   % just one repetition
opts.reassign_converge = 0;                                   % stop only when no points are reassigned ...
opts.reassign_rough    = round(0.005 * M);                    % (no need to get full convergence for intermediate runs)
opts.mse_converge      = 0;                                   % ... and by default, we don't use the mse convergence criterion
opts.progress          = 1;
opts.split_big         = 0;
if (nargin > 1)
    supplied = lower(fieldnames(options));   % which options did the user specify?
    for op = 1:length(supplied)              % copy those over the defaults
        opts.(supplied{op}) = options.(supplied{op});
    end
end

%% CLUSTERING
wavelist   = (1:M)';
assigns    = ones(M, opts.reps,'single');
mse        = Inf * ones(1, opts.reps);
randnstate = randn('state');

for rep = 1:opts.reps                                 % TOTAL # REPETITIONS
    
    centroid = mean(waves, 1);  % always start here
    itercounter = zeros(opts.divisions,1);
    
    for iter = 1:opts.divisions                       % # K-MEANS SPLITS
        oldmse            = Inf;
        oldassigns        = zeros(M,1,'single');
        assign_converge   = 0;
        mse_converge      = 0;
        itercounter(iter) = 0;
        
        %         if (iter == opts.divisions); reassign_criterion = opts.reassign_converge;
        %         else                         reassign_criterion = opts.reassign_rough;
        %         end
        
        reassign_criterion = opts.reassign_rough;
        
        if (opts.split_big)
            if (iter == opts.divisions)  % do some extra splitting on clusters that look too big
                toobig   = find(clustersizes > 2*target_clustersize);
                splitbig = centroid(toobig,:) + randn(length(toobig), size(centroid,2));
                centroid = [centroid; splitbig];
            end
        end
        
        centroid = [centroid; centroid] + jitter * randn(2*size(centroid,1), size(centroid,2)); % split & jitter
        
        if (opts.progress)
            progress_bar(0, 1, sprintf('Calculating %d means.', size(centroid,1))); % crude ...
        end
        
        while (~(assign_converge || mse_converge)) % convergence?
            numclusts = size(centroid,1);  % this might not be 2^iter if any have been emptied
            
            %%%%% E STEP
            % Vectorized distance computation:
            %         dist(x,y)^2 = (x-y)'(x-y) = x'x + y'y - 2 x'y,
            % which can be done simultaneously for all spikes ...
            % ... and simultaneously get cluster assignments by asking for minimum distance^2
            clustdistsq = bsxfun(@plus,dot(waves,waves,2),dot(centroid,centroid,2)')-(2*waves*centroid');
            [~,assigns(:,rep)] = min(clustdistsq,[],2);
            bestdists = clustdistsq(sub2ind([M,numclusts], wavelist, assigns(:,rep)));
            
            % Prevent singleton clusters because they screw up later calculations.
            clustersizes = hist(assigns(:,rep), 1:numclusts);
            while (any(clustersizes == 1))
                singleton   = find(clustersizes == 1);
                singleton   = singleton(1);                        % pick a singleton ...
                singlespike = find(assigns(:,rep) == singleton);   % ... and its lone member ...
                clustdistsq(singlespike, singleton) = single(Inf); % ... and find its next best assignment
                [bestdists(singlespike), assigns(singlespike, rep)] = min(clustdistsq(singlespike,:));
                clustersizes(singleton) = 0;                       % bookkeeping for cluster counts
                clustersizes(assigns(singlespike, rep)) = clustersizes(assigns(singlespike, rep)) + 1;
            end
            
            %%%%% M STEP
            % Recompute cluster means based on new assignments . . .
            
            centroid = zeros(numclusts, N);
            
            for iclust = 1:numclusts
                centroid(iclust,:) = sum(waves(assigns == iclust,:));
            end
            
            id = clustersizes > 0;
            centroid(id,:) = bsxfun(@rdivide,centroid(id,:),clustersizes(id)');
            
            centroid(clustersizes == 0,:)   = [];
            clustersizes(clustersizes == 0) = [];
            
            %%%%% Compute convergence info
            mse(rep)     = mean(bestdists);
            mse_converge = (1 - (mse(rep)/oldmse)) <= opts.mse_converge;   % fractional change
            oldmse       = mse(rep);
            
            changed_assigns = sum(assigns(:,rep) ~= oldassigns);
            assign_converge = changed_assigns <= reassign_criterion;   % num waveforms reassigned
            
            oldassigns = assigns(:,rep);
            itercounter(iter) = itercounter(iter) + 1;
            
            if (mod(itercounter(iter),5) == 0)
                tot = size(assigns,1) - reassign_criterion;
                progress_bar((tot - changed_assigns) / tot,[]);
            end
        end
    end
end

spikes.info.kmeans.iteration_count = itercounter;
spikes.info.kmeans.randn_state = randnstate;

% Finish up by selecting the lowest mse over repetitions.
[bestmse, choice] = min(mse);
spikes.info.kmeans.assigns = single(sort_assignments(assigns(:,choice))');
spikes.info.kmeans.mse = bestmse;

% We also save the winning cluster centers as a convenience
numclusts = max(spikes.info.kmeans.assigns);
spikes.info.kmeans.centroids = zeros(numclusts, N);
for iclust = 1:numclusts
    spikes.info.kmeans.centroids(iclust,:) = mean(waves(spikes.info.kmeans.assigns == iclust,:), 1);
end

% And W, B, T matrices -- easy since T & B are fast to compute and T = W + B)
spikes.info.kmeans.T = cov(waves); % normalize everything by M-1, not M
spikes.info.kmeans.B = cov(spikes.info.kmeans.centroids(spikes.info.kmeans.assigns, :));
spikes.info.kmeans.W = spikes.info.kmeans.T - spikes.info.kmeans.B;

% Finally, assign colors to the spike clusters here for consistency ...
cmap = jetm(numclusts);
spikes.info.kmeans.colors = cmap(randperm(numclusts),:);
if (opts.progress), progress_bar(1.0, 1, ''); end

spikes.info.kmeans.num_clusters = numclusts;