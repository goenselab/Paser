function psr_plot_stacking(h)

% See: https://stackoverflow.com/a/11758610 (by Gunther Struyf)
% h(1): top plot
% h(2): bottom plot

linkaxes([h(1),h(2)],'x')

set(h(1),'xticklabel',[]);        
pos    = get(h,'position');
bottom = pos{2}(2);
top    = pos{1}(2) + pos{1}(4);
plotspace = top - bottom;
pos{2}(4) = plotspace / 2;
pos{1}(4) = plotspace / 2;
pos{1}(2) = bottom + plotspace / 2;

set(h(1),'position',pos{1});
set(h(2),'position',pos{2});

% Fix alignment in case of colorbar
pos1 = get(h(1),'Position');
pos2 = get(h(2),'Position');
pos2(3) = pos1(3);
set(h(2),'Position',pos2)

% Move y-labels to the right
set(h(2),'YAxisLocation','right');
        
end