#= Run ADAPT-QAOA on a MaxCut Hamiltonian. =#

import Graphs
import ADAPT
import PauliOperators: ScaledPauliVector, FixedPhasePauli, KetBitString, SparseKetBasis
import LinearAlgebra: norm

# DEFINE A GRAPH
n = 6

# EXAMPLE OF ERDOS-RENYI GRAPH
prob = 0.5
g = Graphs.erdos_renyi(n, prob)

# EXAMPLE OF ANOTHER ERDOS-RENYI
#ne = 7
#g = Graphs.erdos_renyi(n, ne)

# EXTRACT MAXCUT FROM GRAPH
e_list = ADAPT.Hamiltonians.get_unweighted_maxcut(g)

# BUILD OUT THE PROBLEM HAMILTONIAN
H = ADAPT.Hamiltonians.maxcut_hamiltonian(n, e_list)

# ANOTHER WAY TO BUILD OUT THE PROBLEM HAMILTONIAN
#d = 3 # degree of regular graph
#H = ADAPT.Hamiltonians.MaxCut.random_regular_max_cut_hamiltonian(n, d)
println("Observable data type: ",typeof(H))

# EXACT DIAGONALIZATION
module Exact
    import ..H
    using LinearAlgebra
    Hm = Matrix(H); E, U = eigen(Hm) # NOTE: Comment out after first run when debugging.
    ψ0 = U[:,1]
    E0 = real(E[1])
end
println("Exact ground-state energy: ",Exact.E0)

# BUILD OUT THE POOL
pool = ADAPT.ADAPT_QAOA.QAOApools.qaoa_double_pool(n)

# ANOTHER POOL OPTION
#pool = ADAPT.Pools.two_local_pool(n)

println("Generator data type: ", typeof(pool[1]))
println("Note: in the current ADAPT-QAOA implementation, the observable and generators must have the same type.")

# CONSTRUCT A REFERENCE STATE
ψ0 = ones(ComplexF64, 2^n) / sqrt(2^n); ψ0 /= norm(ψ0)

# INITIALIZE THE ANSATZ AND TRACE
ansatz = ADAPT.ADAPT_QAOA.QAOAAnsatz(0.1, H) 
# the first argument (a hyperparameter) can in principle be set to values other than 0.1
trace = ADAPT.Trace()

# SELECT THE PROTOCOLS
adapt = ADAPT.VANILLA
vqe = ADAPT.OptimOptimizer(:BFGS; g_tol=1e-6)

# SELECT THE CALLBACKS
callbacks = [
    ADAPT.Callbacks.Tracer(:energy, :selected_index, :selected_score, :scores),
    ADAPT.Callbacks.ParameterTracer(),
    ADAPT.Callbacks.Printer(:energy, :selected_generator, :selected_score),
    ADAPT.Callbacks.ScoreStopper(1e-3),
    ADAPT.Callbacks.ParameterStopper(100),
]

# RUN THE ALGORITHM
ADAPT.run!(ansatz, trace, adapt, vqe, pool, H, ψ0, callbacks)
