using Turing, StatsPlots, Random, FillArrays

# @model function GAM(G, Z)
#     Z
# end

@model function watershed(G, E)
    # Setup
    prior_pseudocounts = 10

    # Extract metadata
    K = size(E[1])

    phi_inlier ~ Dirichlet(Fill(prior_pseudocounts, K))
    phi_outlier ~ Dirichlet(Fill(prior_pseudocounts, K))

    lambda = 0.1
    alpha ~ MvNormal(0, 1 / lambda)
    # no prior for alpha (aka theta_singleton)
    # no prior for beta (aka theta)
    # no prior for omega (aka theta_pair)

    log_p_of_Z = sum
end

filldist(Exponential(), 2)

