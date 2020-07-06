"""
```
convex_clustering(algorithm::AlgorithmOption, weights, data;)
```
"""
function convex_clustering(algorithm::AlgorithmOption, weights, data;
    K::Integer=0,
    o::Base.Ordering=Base.Order.Forward,
    rho::Real=1.0,
    mu::Real=1.0,
    ls::LS=Val(:LSQR), kwargs...) where LS
    #
    # extract problem information
    d, n = size(data)
    m = binomial(n, 2)
    M = d*m
    N = d*n

    # allocate optimization variable
    X = copy(data)
    x = vec(X)
    if algorithm isa ADMM
        y = zeros(M)
        λ = zeros(M)
        variables = (x = x, y = y, λ = λ)
    else
        variables = (x = x,)
    end

    # allocate derivatives
    ∇f = needs_gradient(algorithm) ? similar(x) : nothing
    ∇q = needs_gradient(algorithm) ? similar(x) : nothing
    ∇h = needs_gradient(algorithm) ? similar(x) : nothing
    ∇²f = needs_hessian(algorithm) ? I : nothing
    derivatives = (∇f = ∇f, ∇²f = ∇²f, ∇q = ∇q, ∇h = ∇h)

    # generate operators
    T1 = typeof(o)
    T2 = eltype(data)
    block_norm = zeros(m)
    cache = zeros(m)
    P = BlockSparseProjection{T1,T2}(d, block_norm, cache, K)
    a = copy(x)
    D = CvxClusterFM(d, n)
    if algorithm isa SteepestDescent
        H = nothing
    elseif algorithm isa MM
        H = ProxDistHessian(N, rho, ∇²f, D'D)
    else
        H = ProxDistHessian(N, mu, ∇²f, D'D)
    end
    operators = (D = D, P = P, H = H, a = a)

    # allocate buffers for mat-vec multiplication, projections, and so on
    z = similar(Vector{eltype(x)}, M)
    Pz = similar(z)
    v = similar(z)

    # select linear solver, if needed
    if needs_linsolver(algorithm)
        if ls isa Val{:LSQR}
            b = similar(typeof(x), N+M) # b has two blocks
            linsolver = LSQRWrapper([I;D], x, b)
        else
            b = similar(x)  # b has one block
            linsolver = CGWrapper(D, x, b)
        end
    else
        b = nothing
        linsolver = nothing
    end

    if algorithm isa ADMM
        s = similar(y)
        r = similar(y)
        buffers = (z = z, Pz = Pz, v = v, b = b, s = s, r = r)
    else
        buffers = (z = z, Pz = Pz, v = v, b = b)
    end

    # create views, if needed
    views = nothing

    # pack everything into ProxDistProblem container
    objective = cvxclst_objective
    algmap = cvxclst_iter
    prob = ProxDistProblem(variables, derivatives, operators, buffers, views, linsolver)

    # solve the optimization problem
    optimize!(algorithm, objective, algmap, prob, rho, mu; kwargs...)

    return X
end

"""
```
convex_clustering_path()
```
"""
function convex_clustering_path(algorithm::AlgorithmOption, weights, data;
    rho::Real=1.0,
    mu::Real=1.0,
    ls::LS=Val(:LSQR), kwargs...) where LS
    #
    # extract problem information
    d, n = size(data)
    m = binomial(n, 2)
    M = d*m
    N = d*n

    # allocate optimization variable
    X = copy(data)
    x = vec(X)
    if algorithm isa ADMM
        y = zeros(M)
        λ = zeros(M)
        variables = (x = x, y = y, λ = λ)
    else
        variables = (x = x,)
    end

    # allocate derivatives
    ∇f = needs_gradient(algorithm) ? similar(x) : nothing
    ∇q = needs_gradient(algorithm) ? similar(x) : nothing
    ∇h = needs_gradient(algorithm) ? similar(x) : nothing
    ∇²f = needs_hessian(algorithm) ? I : nothing
    derivatives = (∇f = ∇f, ∇²f = ∇²f, ∇q = ∇q, ∇h = ∇h)

    # generate operators
    a = copy(x)
    D = CvxClusterFM(d, n)

    ρ₀ = algorithm isa ADMM ? mu : rho

    if algorithm isa SteepestDescent
        H = nothing
    elseif algorithm isa MM
        H = ProxDistHessian(N, ρ₀, ∇²f, D'D)
    else
        H = ProxDistHessian(N, ρ₀, ∇²f, D'D)
    end

    # use two versions of operators; probably not a good idea
    T2 = eltype(data)
    block_norm = zeros(m)   # stores column-wise distances
    cache = zeros(m)        # mirrors block_norm; cache for pivot search

    P1 = BlockSparseProjection{MaxParamT,T2}(d, block_norm, cache, 0)
    operators1 = (D = D, P = P1, H = H, a = a)

    P2 = BlockSparseProjection{MinParamT,T2}(d, block_norm, cache, 0)
    operators2 = (D = D, P = P2, H = H, a = a)

    # allocate buffers for mat-vec multiplication, projections, and so on
    z = similar(Vector{eltype(x)}, M)
    Pz = similar(z)
    v = similar(z)

    # select linear solver, if needed
    if needs_linsolver(algorithm)
        if ls isa Val{:LSQR}
            b = similar(typeof(x), N+M) # b has two blocks
            linsolver = LSQRWrapper([I;D], x, b)
        else
            b = similar(x)  # b has one block
            linsolver = CGWrapper(D, x, b)
        end
    else
        b = nothing
        linsolver = nothing
    end

    if algorithm isa ADMM
        s = similar(y)
        r = similar(y)
        buffers = (z = z, Pz = Pz, v = v, b = b, s = s, r = r)
    else
        buffers = (z = z, Pz = Pz, v = v, b = b)
    end

    # create views, if needed
    views = nothing

    # pack everything into ProxDistProblem container
    objective = cvxclst_objective
    algmap = cvxclst_iter

    prob1 = ProxDistProblem(variables, derivatives, operators1, buffers, views, linsolver)

    prob2 = ProxDistProblem(variables, derivatives, operators2, buffers, views, linsolver)

    # allocate output
    X_path = typeof(X)[]
    ν_path = Int[]

    # initialize solution path heuristic
    νmax = binomial(n, 2)
    ν = νmax-1

    prog = ProgressThresh(0, "Searching clustering path")
    while ν ≥ 0
        # this is an unavoidable branch made worse by parameterization of
        # projection operator
        if ν ≤ (νmax >> 1)
            P1 = BlockSparseProjection{MaxParamT,T2}(d, block_norm, cache, ν)
            operators1 = (D = D, P = P1, H = H, a = a)
            prob1 = ProxDistProblem(variables, derivatives, operators1, buffers, views, linsolver)
            if uses_CG(prob2)
                prob1 = update_operators(prob1, ρ₀)
            end
            optimize!(algorithm, objective, algmap, prob1, rho, mu; kwargs...)
        else
            P2 = BlockSparseProjection{MinParamT,T2}(d, block_norm, cache, νmax - ν)
            operators2 = (D = D, P = P2, H = H, a = a)
            prob2 = ProxDistProblem(variables, derivatives, operators2, buffers, views, linsolver)
            if uses_CG(prob2)
                prob2 = update_operators(prob2, ρ₀)
            end
            optimize!(algorithm, objective, algmap, prob2, rho, mu; kwargs...)
        end

        # record current solution
        push!(X_path, copy(X))
        push!(ν_path, ν)

        # count satisfied constraints
        nconstraint = 0
        distance = pairwise(SqEuclidean(), X, dims = 2)
        for j in 1:n, i in j+1:n
            # distances within 10^-3 are 0
            nconstraint += (log(10, abs(weights[i,j] * distance[i,j])) ≤ -3)
        end

        # decrease ν with a heuristic that guarantees a decrease
        ν = min(ν - 1, νmax - nconstraint - 1)
        ProgressMeter.update!(prog, ν)
    end

     solution_path = (U = X_path, ν = ν_path)

    return solution_path
end

#########################
#       objective       #
#########################

function cvxclst_objective(::AlgorithmOption, prob, ρ)
    @unpack x = prob.variables
    @unpack ∇f, ∇q, ∇h = prob.derivatives
    @unpack D, P, a = prob.operators
    @unpack z, Pz, v = prob.buffers

    # evaulate gradient of loss
    @. ∇f = x - a

    # evaluate gradient of penalty
    mul!(z, D, x)
    P(Pz, z)        # TODO: figure out how to fix this ugly notation
    @. v = z - Pz
    mul!(∇q, D', v)
    @. ∇h = ∇f + ρ * ∇q

    loss = SqEuclidean()(x, a) / 2
    penalty = dot(v, v)
    normgrad = dot(∇h, ∇h)

    return loss, penalty, normgrad
end

############################
#      algorithm maps      #
############################

function cvxclst_iter(::SteepestDescent, prob, ρ, μ)
    @unpack x = prob.variables
    @unpack ∇h = prob.derivatives
    @unpack D = prob.operators
    @unpack z = prob.buffers

    # evaluate step size, γ
    mul!(z, D, ∇h)
    a = dot(∇h, ∇h)     # ||∇h(x)||^2
    b = dot(z, z)       # ||D*∇h(x)||^2
    γ = a / (a + ρ*b + eps())

    # steepest descent, x_new = x_old - γ*∇h(x_old)
    axpy!(-γ, ∇h, x)

    return γ
end

function cvxclst_iter(::MM, prob, ρ, μ)
    @unpack x = prob.variables
    @unpack D, H, a = prob.operators
    @unpack b, Pz = prob.buffers
    linsolver = prob.linsolver

    if linsolver isa LSQRWrapper
        # build LHS of A*x = b
        # forms a BlockMap so non-allocating
        # however, A*x and A'b have small allocations due to views?
        A = [I; √ρ*D]

        # build RHS of A*x = b; b = [a; √ρ * P(D*x)]
        n = length(a)
        copyto!(b, 1, a, 1, n)
        for k in eachindex(Pz)
            b[n+k] = √ρ * Pz[k]
        end
    else
        # LHS of A*x = b is already stored
        A = H

        # build RHS of A*x = b; b = a + ρ*D'P(D*x)
        mul!(b, D', Pz)
        axpby!(1, a, ρ, b)
    end

    # solve the linear system
    linsolve!(linsolver, x, A, b)

    return 1.0
end

function cvxclst_iter(::ADMM, prob, ρ, μ)
    @unpack x, y, λ = prob.variables
    @unpack D, H, P, a = prob.operators
    @unpack z, Pz, v, b = prob.buffers
    linsolver = prob.linsolver

    # x block update
    @. v = y - λ
    if linsolver isa LSQRWrapper
        # build LHS of A*x = b
        # forms a BlockMap so non-allocating
        # however, A*x and A'b have small allocations due to views?
        A = [I; √μ*D]

        # build RHS of A*x = b; b = [a; √μ * (y-λ)]
        n = length(a)
        copyto!(b, 1, a, 1, length(a))
        for k in eachindex(v)
            @inbounds b[n+k] = √μ * v[k]
        end
    else
        # LHS of A*x = b is already stored
        A = H

        # build RHS of A*x = b; b = a + μ*D'(y-λ)
        mul!(b, D', v)
        axpby!(1, a, μ, b)
    end

    # solve the linear system
    linsolve!(linsolver, x, A, b)

    # y block update
    α = (ρ / μ)
    @. v = z + λ; Pv = Pz; P(Pv, v)
    @inbounds @simd for j in eachindex(y)
        y[j] = α/(1+α) * Pv[j] + 1/(1+α) * v[j]
    end

    # λ block update
    mul!(z, D, x)
    @inbounds @simd for j in eachindex(λ)
        λ[j] = λ[j] + μ * (z[j] - y[j])
    end

    return μ
end

#################
#   utilities   #
#################

"""
Finds the connected components of a graph.
Nodes should be numbered 1,2,...
"""
function connect!(component, A)
#
    nodes = size(A, 1)
    fill!(component, 0)
    components = 0
    for j = 1:nodes
        if component[j] > 0 continue end
        components = components + 1
        component[j] = components
        visit!(component, A, j)
    end
    return (component, components)
end

"""
Recursively assigns components by depth first search.
"""
function visit!(component, A, j::Int)
#
    nodes = size(A, 1)
    for i in 1:nodes
        if A[i,j] == 1 # check that i is a neighbor of j
            if component[i] > 0 continue end
            component[i] = component[j]
            visit!(component, A, i)
        end
    end
end

function assign_classes!(class, A, Δ, U, tol)
    n = size(Δ, 1)

    Δ = pairwise(Euclidean(), U, dims = 2)

    # update adjacency matrix
    for j in 1:n, i in j+1:n
        abs_dist = log(10, Δ[i,j])

        if (abs_dist < -tol)
            A[i,j] = 1
            A[j,i] = 1
        else
            A[i,j] = 0
            A[j,i] = 0
        end
    end

    # assign classes based on connected components
    class, nclasses = connect!(class, A)

    return (A, class, nclasses)
end

function assign_classes(U, tol = 3.0)
    n = size(U, 2)
    A = zeros(Bool, n, n)
    Δ = zeros(n, n)
    class = zeros(Int, n)

    return assign_classes!(class, A, Δ, U, tol)
end

"""
```
gaussian_weights(X; [phi = 1.0])
```

Assign weights to each pair of samples `(i,j)` based on a Gaussian kernel.
The parameter `phi` scales the influence of the distance `norm(X[:,i] - X[:,j])^2`.

**Note**: Samples are assumed to be given in columns.
"""
function gaussian_weights(X; phi = 0.5)
    d, n = size(X)

    T = eltype(X)
    W = zeros(n, n)

    for j in 1:n, i in j+1:n
        @views δ_ij = SqEuclidean()(X[:,i], X[:,j])
        w_ij = exp(-phi*δ_ij)

        W[i,j] = w_ij
        W[j,i] = w_ij
    end

    return W
end

"""
```
knn_weights(W, k)
```

Threshold weights `W` based on `k` nearest neighbors.
"""
function knn_weights(W, k)
    n = size(W, 1)
    w = [W[i,j] for j in 1:n for i in j+1:n] |> vec
    i = 1
    neighbors = tri2vec.((i+1):n, i, n)
    keep = neighbors[sortperm(w[neighbors], rev = true)[1:k]]

    for i in 2:(n-1)
        group_A = tri2vec.((i+1):n, i, n)
        group_B = tri2vec.(i, 1:(i-1), n)
        neighbors = [group_A; group_B]
        knn = neighbors[sortperm(w[neighbors], rev = true)[1:k]]
        keep = union(knn, keep)
    end

    i = n
    neighbors = tri2vec.(i, 1:(i-1), n)
    knn = neighbors[sortperm(w[neighbors], rev = true)[1:k]]
    keep = union(knn, keep)

    W_knn = zero(W)

    for j in 1:n, i in j+1:n
        l = tri2vec(i, j, n)
        if l in keep
            W_knn[i,j] = W[i,j]
            W_knn[j,i] = W[i,j]
        end
    end

    return W_knn
end

"""
```
gaussian_clusters(centers, n)
```

Simulate a cluster with `n` points centered at the given `centroid`.
"""
function gaussian_cluster(centroid, n)
    d = length(centroid)
    cluster = centroid .+ 0.1 * randn(d, n)

    return cluster
end

#################
#   examples    #
#################

function convex_clustering_data(file)
    dir = dirname(@__DIR__) # should point to src
    dir = dirname(dir)      # should point to top-level directory

    df = CSV.read(joinpath(dir, "data", file), copycols = true)

    if basename(file) == "mammals.dat" # classes in column 2
        # extract data as features × columns
        data = convert(Matrix{Float64}, df[:, 3:end-1])
        X = copy(transpose(data))

        # retrieve class assignments
        class_name = unique(df[:,2])
        classes = convert(Vector{Int}, indexin(df[:,2], class_name))
    else # classes in last column
        # extract data as features × columns
        data = convert(Matrix{Float64}, df[:,1:end-1])
        X = copy(transpose(data))

        # retrieve class assignments
        class_name = unique(df[:,end])
        classes = convert(Vector{Int}, indexin(df[:,end], class_name))
    end

    return X, classes, length(class_name)
end
