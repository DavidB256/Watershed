using Turing, StatsPlots, Random

# @model function GAM(G, Z)
#     Z
# end

@model function watershed(G, E)
    # Setup
    prior_pseudocounts = 10

    # Extract metadata
    K = size(E[1])

    phi_inlier ~ Dirichlet(fill(prior_pseudocounts, K))
    phi_outlier ~ Dirichlet(fill(prior_pseudocounts, K))
    # no prior for alpha (aka theta_singleton)
    # no prior for beta (aka theta)
    # no prior for omega (aka theta_pair)

    log_p_of_Z = sum
end

filldist(Exponential(), 2)



sum(x, dims=1)