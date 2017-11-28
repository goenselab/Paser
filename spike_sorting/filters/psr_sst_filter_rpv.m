function spikes = psr_sst_filter_rpv(spikes,parameters,method)

PC = psr_pca(spikes,parameters.cluster.pca_dims);

nClusts = length(unique(spikes.assigns));
spikes.rpvs = zeros(nClusts,1); 

for iClust = 1:nClusts
    
    show = get_spike_indices(spikes, iClust);
    
    PC_clust = PC(show,:);
    
    nspikes = length(show);
    if (nspikes <= parameters.cluster.min_spikes); continue; end
        
    % Find refractory period violations (RPVs)
    
    spiketimes   = spikes.spiketimes(show);
    rpvs         = diff(spiketimes) <= 0.001 * parameters.spikes.ref_period;
    rpvs         = [0,rpvs]; %#ok
    rpvs         = find(rpvs);
    id           = zeros(size(spiketimes));
    id(rpvs)     = 1;
    id(rpvs - 1) = 1;
    id           = find(id);
    
    % Each RPV involves two or more spike. We remove enough spikes to resolve
    % the RPV, where we keep the spikes that have the smallest Mahalanobis
    % distance to cluster
    
    nRPVs = length(id);
    itr   = 1;
    del   = [];
    n     = 0;
    
    while (itr < nRPVs)
        if (spiketimes(id(itr+1)) - spiketimes(id(itr)) <= 0.001 * parameters.spikes.ref_period)
            v     = [id(itr);id(itr+1)];
            itrV  = [itr;itr+1];
            [~,I] = max(mahal(PC_clust(v,:),PC_clust));
            I1    = itrV(I);
            I2    = v(I);
            spiketimes(I2) = [];
            PC_clust(I2,:) = [];
            id(I1:end)     = id(I1:end) - 1;
            id(I1)         = [];
            del = [del;I2+n]; %#ok
            nRPVs = nRPVs - 1;
            itr   =   itr - 1;
            n     =     n + 1;
        end
        
        itr = itr + 1;
    end
    
    id = show(del);
    spikes = psr_sst_spike_removal(spikes,id,method);
    spikes.rpvs(iClust) = length(id) / nspikes;
end

end