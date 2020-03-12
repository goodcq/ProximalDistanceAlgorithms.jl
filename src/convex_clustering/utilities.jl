"""
Finds the connected components of a graph.
Nodes should be numbered 1,2,...
"""
function connect(neighbor::Array{Array{Int, 1}, 1})
#
  nodes = length(neighbor)
  component = zeros(Int, nodes)
  components = 0
  for i = 1:nodes
    if component[i] > 0 continue end
    components = components + 1
    component[i] = components
    visit!(neighbor, component, i)
  end
  return (component, components)
end

"""
Recursively assigns components by depth first search.
"""
function visit!(neighbor::Array{Array{Int,1},1},
  component::Vector{Int}, i::Int)
#
  for j in neighbor[i]
    if component[j] > 0 continue end
    component[j] = component[i]
    visit!(neighbor, component, j)
  end
end

"""
Collects neighborhoods and weights from an adjacency matrix A.
"""
function adjacency_to_neighborhood(A::Matrix)
#
  (nodes, T) = (size(A, 1), eltype(A))
  neighbor = [Vector{Int}() for i = 1:nodes]
  weight = [Vector{T}() for i = 1:nodes]
  for i = 1:nodes
    for j = 1:nodes
      if A[i, j] != zero(T)
        push!(neighbor[i], j)
        push!(weight[i], A[i, j])
      end
    end
  end
  return (neighbor, weight)
end

function get_cluster_assignment(W, U, tol)
    d, n = size(U)

    # adjacency matrix
    A = [W[i,j]*norm(U[:,i] - U[:,j]) for i in 1:n, j in 1:n]

    for K in eachindex(A)
      if A[K] < tol
        A[K] = 1
      else
        A[K] = 0
      end
    end

    neighbor, weight = adjacency_to_neighborhood(A)
    component, components = connect(neighbor)

    return component, components
end
