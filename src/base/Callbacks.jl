"""
    Callbacks

A suite of basic callbacks for essential functionality.

# Explanation

The final argument of the `adapt!`, `optimize!` and `run!` methods
    calls for a vector of `Callbacks`.
These are callable objects extending behavior at each iteration or adaptation
    (or both; see the `AbstractCallback` type documentation for more details).

The callback is passed a `data` object
    (aka. a `Dict` where the keys are `Symbols` like `:energy` or `:scores`),
    in addition to the ADAPT state and all the quantum objects.
Callbacks may be as simple as displaying the `data`,
    or as involved as carefully modifying the quantum objects to satsify some constraint.

Each callback in this module can be categorized as one of the following:
1. Tracers: update the running `trace` with information passed in `data`
2. Printers: display the information passed in `data` to the screen or to a file
3. Stoppers: flag the ADAPT state as converged, based on some condition

In particular, Stoppers are the primary means of establishing convergence in Vanilla ADAPT.
They do this by flagging the ADAPT state as converged,
    which signals to the `run!` function that it can stop looping once this round is done.
Alternatively, though none of the basic callbacks in this module do so,
    you amy implement a callback that returns `true` based on some condition.
This signals an instant termination, regardless of convergence.

Just to reiterate, Stoppers are the *primary means of establishing convergence*.
If you don't include any callbacks, the `run!` call may not terminate this century!

# Callback Order

Callback order matters.
Using the callbacks in this module, I recommend the order listed above
    (Tracers, then Printers, then Stoppers).

The first callback in the list gets dibs on mutating the trace or the ADAPT state,
    which could change the behavior of subsequent callbacks.
For example, the basic `Printer` inspects the trace to infer the current iteration,
    so it naturally follows the `Tracer`.
    (although the `Printer` knows to skip this part if there *is* no `Tracer`).
Some Stoppers (eg. `SlowStopper`, `FloorStopper`)
    inspect the trace to decide whether energy has converged,
    so the "latest" energy should already be logged.
Therefore, these too should follow the `Tracer`.

Please note that, because the callbacks are called prior to actually updating the ansatz,
    the Tracer will usually log one last round of updates
    which are not actually reflected in the ansatz.
The only times this does not happen are if convergence is flagged by the protocol itself
    rather than a Stopper callback (eg. all scores are essentially zero),
    which is probably never. ^_^
This behavior seems fine, even desirable, to me, but if you'd like to avoid it,
    you could implement a Stopper which explicitly terminates by returning `true`
    (rather than merely flagging the ansatz as converged, like basic Stoppers),
    and listing that Stopper *prior* to the Tracer.

# Standard keys

The actual keys used in the `data` argument are determined by the protocol,
    so you may design custom callbacks to make use of the data in your custom protocols.

However, for the sake of modularity, it is worth keeping keys standardized when possible.
Here is a list of recommended keys.

## Reserved keys
- `:iteration`: iteration count over all optimizations
- `:adaptation`: which iteration an adaptation occurred

These keys are not part of `data` but are used in the running `trace`.

## Standard keys for `adapt!`
- `:scores`: vector of scores for each pool operator
- `:selected_index`: index in the pool of the operator ADAPT plans to add
- `:selected_generator`: the actual generator object ADAPT plans to add
- `:selected_parameter`: the parameter ADAPT plans to attach to the new generator

Protocols which add multiple generators in a single adaptation
    may still use these same keys, replacing the values with vectors.

## Standard keys for `optimize!`
- `:energy`: the result of evaluating the observable. Required for some Stoppers
- `:g_norm`: the norm of the gradient vector (typically ∞ norm, aka. largest element)
- `:elapsed_iterations`: the number of iterations of the present optimization run
- `:elapsed_time`: time elapsed since starting the present optimization run
- `:elapsed_f_calls`: number of function calls since starting the present optimization run
- `:elapsed_g_calls`: number of gradient calls since starting the present optimization run

"""
module Callbacks
    import Serialization

    import ..ADAPT
    import ..ADAPT: AbstractCallback
    import ..ADAPT: Data, AbstractAnsatz, Trace
    import ..ADAPT: AdaptProtocol, OptimizationProtocol
    import ..ADAPT: GeneratorList, Observable, QuantumState

    """
        Tracer(keys::Symbol...)

    Add selected data keys at each iteration or adaptation to the running trace.

    # Examples

        Tracer(:energy)

    Including this callback in a `run!` call will fill the `trace` argument
        with the energy at each optimization iteration,
        as well as noting in which iteration each adaptation occurred.
    I cannot think of a circumstance when you will not want to trace at least this much.

        Tracer(:energy, :scores)

    This example shows the syntax to keep track of multiple data keys:
        just list them out as successive arguments of the same `Tracer`.
    Do NOT include multiple instances of `Tracer` in the same run,
        or you will record twice as many iterations as actually occurred!
    The `ParameterTracer` is a distinct type and is safe to use with `Tracer`.

    # Other Notes

    If a key is not present in `data`, it is ignored.
    Thus, the same list of keys is used for calls from `adapt!` and `optimize!`,
        so long as keys do not overlap (which should be avoided)!

    The keys `:iteration` and `:adaptation` are treated specially.
    These keys will not appear directly in `data`,
        and they should not be included in `keys`.

    The `:iteration` value will simply increment with each call from `optimize!`.
    The `:adaptation` value will be set to the most recent `:iteration` value.

    I highly recommend including at minimum `Tracer(:energy)`
        with every single ADAPT run you ever do.

    """
    struct Tracer <: AbstractCallback
        keys::Vector{Symbol}
    end

    Tracer(keys::Symbol...) = Tracer(collect(keys))

    function (tracer::Tracer)(
        data::Data, ::AbstractAnsatz, trace::Trace,
        ::AdaptProtocol, ::GeneratorList, ::Observable, ::QuantumState,
    )
        iterations = get(trace, :iteration, Int[])
        adaptations = get!(trace, :adaptation, Int[])
        push!( adaptations, length(iterations) )
        for key in tracer.keys
            key ∉ keys(data) && continue
            push!( get!(trace, key, Any[]), data[key] )
        end
        return false
    end

    function (tracer::Tracer)(
        data::Data, ::AbstractAnsatz, trace::Trace,
        ::OptimizationProtocol, ::Observable, ::QuantumState,
    )
        iterations = get!(trace, :iteration, Int[])
        this_iteration = isempty(iterations) ? 1 : 1+last(iterations)
        push!( iterations, this_iteration )
        for key in tracer.keys
            key ∉ keys(data) && continue
            push!( get!(trace, key, Any[]), data[key] )
        end
        return false
    end


    # """
    #     ParameterTracer()

    # Add the ansatz parameters to the running trace, under the key `:parameters`.

    # Called for `adapt!` only.

    # Each parameter is stored as a column in a matrix; each row is a different iteration.
    # The existing trace is padded with columns of 0.0
    #     to match the current number of parameters before a new row is added.

    # Concatenating either rows or columns to a matrix is rather expensive
    #     (it involves creating an entirely new matrix in each call),
    #     so use this callback with care.

    # Please note that the default implementation of this callback is unsuitable
    #     (or at least the matrix requires some post-processing)
    #     if the AdaptProtocol reorders parameters,
    #     or even simply inserts new parameters anywhere other than the end.
    # If you need a parameter tracer for such protocols,
    #     you're probably best off implementing a new callback from scratch.
    # (Maybe you could implement some clever permutation in the `adapt!` call?
    #     But remember the callback is called *before* the parameter is added!)

    # """
    # struct ParameterTracer <: AbstractCallback end

    # function (tracer::ParameterTracer)(
    #     ::Data, ansatz::AbstractAnsatz, trace::Trace,
    #     ::AdaptProtocol, ::GeneratorList, ::Observable, ::QuantumState,
    # )
    #     F = ADAPT.typeof_parameter(ansatz)
    #     matrix = get(trace, :parameters, Matrix{F}(undef, 0, 0))

    #     # PAD THE EXISTING MATRIX WITH ZEROS TO MATCH THE SIZE OF THE CURRENT ANSATZ
    #     num_new_parameters = length(ansatz) - size(matrix, 2)
    #     if num_new_parameters > 0
    #         pad = zeros(F, size(matrix,1), num_new_parameters)
    #         matrix = hcat(matrix, pad)
    #     end

    #     # APPEND THE CURRENT PARAMETERS
    #     matrix = vcat(matrix, transpose(ADAPT.angles(ansatz)))
    #     trace[:parameters] = matrix

    #     return false
    # end


    """
        ParameterTracer()

    Add the ansatz parameters to the running trace, under the key `:parameters`.

    Only compatible when following a Tracer including :selected_index.
    This is no great handicap since the principal point of this is
        to be able to reconstruct an ansatz,
        and you'll need the :selected_index for that also. ;)

    Parameters are stored in a matrix.
    Each column is associated with an angle in the ansatz
        (vanilla protocol sets the first column as the first parameter added to the ansatz
        and the first one applied to the reference state).
    Each row gives the optimized parameters for the corresponding ADAPT iteration.

    The adapt callback is responsible for adding a new row
        (vanilla protocol is to initialize with the previously optimized parameters),
        and for padding previous rows with zeros.
    The optimization callback is responsible for keeping the last row updated
        with the currently-best parameters for this choice of parameters.

    Standard practice is to include the ParameterTracer AFTER the regular Tracer,
        but BEFORE any ADAPT convergence Stoppers.
    Thus, the parameter matrix INCLUDES columns for the last-selected parameter(s).
    Standard practice for reconstructing an optimized ansatz of a converged trace
        is to look at the PENULTIMATE row.

    Please note that the default implementation of this callback is unsuitable
        (or at least the matrix requires some post-processing)
        if the AdaptProtocol reorders parameters,
        or even simply inserts new parameters anywhere other than the end,
        or even (currently) if parameters aren't initialized to zero,
        or even (currently) if it adds more than one parameter at once.
    (NOTE: These last two are easily adjusted
        but will require a more complex `trace` precondition.)
    If you need a parameter tracer for such protocols,
        you'll need to dispatch to your own method.

    """
    struct ParameterTracer <: AbstractCallback end

    function (tracer::ParameterTracer)(
        ::Data, ansatz::AbstractAnsatz, trace::Trace,
        ::AdaptProtocol, ::GeneratorList, ::Observable, ::QuantumState,
    )
        F = ADAPT.typeof_parameter(ansatz)
        matrix = get(trace, :parameters, Matrix{F}(undef, 0, 0))

        # GET THE CURRENT PARAMETERS AND NEW PARAMETERS
        n0 = size(matrix, 2)                        # CURRENT # OF PARAMETERS
        n = length(get(trace, :selected_index, 0))  # NEW # OF PARAMETERS
        Δn = n - n0                                 # # OF NEW PARAMETERS

        # DUPLICATE THE FINAL ROW
        if size(matrix, 1) == 0     # FIRST ADAPTATION: no parameters to copy
            matrix = Matrix{F}(undef, 1, n0)
        else
            matrix = vcat(matrix, matrix[end:end,:])
        end

        # PAD THE EXISTING MATRIX WITH ZEROS TO MATCH THE SIZE OF THE CURRENT ANSATZ
        if Δn > 0
            pad = zeros(F, size(matrix,1), Δn)
            matrix = hcat(matrix, pad)
        end
        trace[:parameters] = matrix

        return false
    end

    function (tracer::ParameterTracer)(
        data::Data, ansatz::AbstractAnsatz, trace::Trace,
        ::OptimizationProtocol, ::Observable, ::QuantumState,
    )
        F = ADAPT.typeof_parameter(ansatz)
        matrix = get(trace, :parameters, Matrix{F}(undef, 0, 0))
        x = ADAPT.angles(ansatz)

        # PAD CURRENT MATRIX IF IT ISN'T LONG ENOUGH
        #= NOTE: This should only happen in edge cases
            like when the user is manually constructin their own ansatz
            and doesn't pre-initialize the :parameter matrix. =#
        if size(matrix, 1) == 0
            matrix = Matrix{F}(undef, 1, size(matrix, 2))
        end
        
        Δn = length(x) - size(matrix, 2)
        if Δn > 0
            pad = zeros(F, size(matrix,1), Δn)
            matrix = hcat(matrix, pad)
            trace[:parameters] = matrix
        end

        # SET THE LAST ROW
        matrix[end,:] .= x

        return false
    end




    """
        Printer([io::IO=stdout,] keys::Symbol...)

    Print selected data keys at each iteration or adaptation.

    The `keys` arguments are passed in the same way as `Tracer`;
        see that method for some examples.
    Unlike `Tracer`, the first argument can be an `IO` object,
        which determines where the printing is done.
    By default, it is the standard output stream, ie. your console,
        or a file if you are redirecting output via `>`.
    The `io` argument allows you to *explicitly* write to a file,
        via Julia's `open` function.

    If a key is not present in `data`, it is ignored.
    Thus, the same list of keys is used for calls from `adapt!` and `optimize!`,
        so long as keys do not overlap (which should be avoided)!

    The keys `:iteration` and `:adaptation` are treated specially.
    These keys will not appear directly in `data`,
        and they should not be included in `keys`.
    If the `trace` contains these keys (ie. if a `Tracer` callback was also included),
        they are used as "section headers".
    Otherwise, they are skipped.

    """
    struct Printer <: AbstractCallback
        io::IO
        keys::Vector{Symbol}
    end

    Printer(io::IO, keys::Symbol...) = Printer(io, collect(keys))
    Printer(keys::Symbol...) = Printer(stdout, collect(keys))

    function (printer::Printer)(
        data::Data, ::AbstractAnsatz, trace::Trace,
        ::AdaptProtocol, ::GeneratorList, ::Observable, ::QuantumState,
    )
        if :adaptation in keys(trace)
            println(printer.io, "--- Adaptation #$(length(trace[:adaptation])) ---")
        end
        for key in printer.keys
            key ∉ keys(data) && continue
            println(printer.io, "$(string(key)): $(data[key])")
        end
        println(printer.io)
        flush(printer.io)
        return false
    end

    function (printer::Printer)(
        data::Data, ::AbstractAnsatz, trace::Trace,
        ::OptimizationProtocol, ::Observable, ::QuantumState,
    )
        if :iteration in keys(trace)
            println(printer.io, ": Iteration #$(length(trace[:iteration])) :")
        end
        for key in printer.keys
            key ∉ keys(data) && continue
            println(printer.io, "$(string(key)): $(data[key])")
        end
        println(printer.io)
        flush(printer.io)
        return false
    end


    #= TODO: A specialized energy printer,
        which lets you receive updates at adaptations rather than iterations.
        It would need to either inspect the trace or just do the calculation.
        The latter is potentially expensive for a UI feature,
            but the former is ill-defined at the first adaptation (before any optimization)
            even though the energy is well-defined.
        I guess we could actually just use the trace IF IT IS AVAILABLE,
            and otherwise calculate it?
    =#


    """
        ParameterPrinter(; io=stdout, adapt=true, optimize=false, ncol=8)

    Print the current ansatz parameters as neatly and compactly as I can think to.

    # Parameters
    - `io`: the IO stream to print to
    - `adapt`: print parameters at each adaptation
    - `optimize`: print parameters at each optimization iteration
    - `ncol`: number of parameters to print in one line, before starting another

    """
    struct ParameterPrinter <: AbstractCallback
        io::IO
        adapt::Bool
        optimize::Bool
        ncol::Int
    end

    ParameterPrinter(;
        io = stdout,
        adapt = true,
        optimize = false,
        ncol = 8,
    ) = ParameterPrinter(io, adapt, optimize, ncol)

    function print_parameters(printer::ParameterPrinter, ansatz::AbstractAnsatz)
        println(printer.io, "*** Parameters ***")
        #= TODO: Explicit tabulation with printf =#
        for i in eachindex(ansatz)
            _, parameter = ansatz[i]
            print(printer.io, "$parameter\t")
            i % printer.ncol == 0 && println(printer.io)
        end
        println(printer.io)
        flush(printer.io)
    end

    function (printer::ParameterPrinter)(
        ::Data, ansatz::AbstractAnsatz, ::Trace,
        ::AdaptProtocol, ::GeneratorList, ::Observable, ::QuantumState,
    )
        printer.adapt && print_parameters(printer, ansatz)
        return false
    end

    function (printer::ParameterPrinter)(
        ::Data, ansatz::AbstractAnsatz, ::Trace,
        ::OptimizationProtocol, ::Observable, ::QuantumState,
    )
        printer.optimize && print_parameters(printer, ansatz)
        return false
    end



    """
        Serializer(; ansatz_file="", trace_file="", on_adapt=false, on_iterate=false)

    Serialize the current state so that it can be resumed more easily.

    Please note that robust serialization depends heavily on version control;
        if the definition of a serialized type has changed since it was serialized,
        it is very, very difficult to recover.
    Thus, serialization of this nature should be considered
        somewhat transient and unreliable.
    It's good for restarting when your supercomputer crashes unexpectedly mid-job,
        but not so good for long-term archival purposes.

    # Parameters
    - `ansatz_file`: file to save ansatz in ("" will skip saving ansatz)
    - `trace_file`: file to save trace in ("" will skip saving trace)
    - `on_adapt`: whether to serialize on adaptations
    - `on_iterate`: whether to serialize in every optimization iteration

    """
    struct Serializer <: AbstractCallback
        ansatz_file::String
        trace_file::String
        on_adapt::Bool
        on_iterate::Bool
    end

    function Serializer(; ansatz_file="", trace_file="", on_adapt=false, on_iterate=false)
        return Serializer(ansatz_file, trace_file, on_adapt, on_iterate)
    end

    function (serializer::Serializer)(
        ::Data, ansatz::AbstractAnsatz, trace::Trace,
        ::AdaptProtocol, ::GeneratorList, ::Observable, ::QuantumState,
    )
        s = serializer  # ALIAS FOR LINE LENGTH
        if s.on_adapt
            isempty(s.ansatz_file) || Serialization.serialize(s.ansatz_file, ansatz)
            isempty(s.trace_file)  || Serialization.serialize(s.trace_file, trace)
        end
        return false
    end

    function (serializer::Serializer)(
        ::Data, ansatz::AbstractAnsatz, trace::Trace,
        ::OptimizationProtocol, ::Observable, ::QuantumState,
    )
        s = serializer  # ALIAS FOR LINE LENGTH
        if s.on_iterate
            isempty(s.ansatz_file) || Serialization.serialize(s.ansatz_file, ansatz)
            isempty(s.trace_file)  || Serialization.serialize(s.trace_file, trace)
        end
        return false
    end



    """
        ParameterStopper(n::Int)

    Converge once the ansatz reaches a certain number of parameters.

    Called for `adapt!` only.

    # Parameters
    - `n`: the minimum number of parameters required for convergence

    """
    struct ParameterStopper <: AbstractCallback
        n::Int
    end

    function (stopper::ParameterStopper)(
        ::Data, ansatz::AbstractAnsatz, ::Trace,
        ::AdaptProtocol, ::GeneratorList, ::Observable, ::QuantumState,
    )
        if length(ansatz) ≥ stopper.n
            ADAPT.set_converged!(ansatz, true)
        end
        return false
    end



    """
        ScoreStopper(threshold::Score)

    Converge if all scores are below a certain threshold.

    Called for `adapt!` only.

    # Parameters
    - `threshold`: the maximum score

    """
    struct ScoreStopper{F<:ADAPT.Score} <: AbstractCallback
        threshold::F
    end

    function (stopper::ScoreStopper)(
        data::Data, ansatz::AbstractAnsatz, ::Trace,
        ::AdaptProtocol, ::GeneratorList, ::Observable, ::QuantumState,
    )
        if maximum(abs.(data[:scores])) < stopper.threshold
            ADAPT.set_converged!(ansatz, true)
        end
        return false
    end





    """
        SlowStopper(threshold::Energy, n::Int)

    Converge if all energies in the past n iterations are within a certain range.

    Called for `adapt!` only. Requires a preceding `Tracer(:energy)`.

    # Parameters
    - `threshold`: maximum energy range before convergence
    - `n`: number of recent adaptations to check

        This function will not flag convergence
            before at least `n` adaptations have occurred.

    """
    struct SlowStopper{F<:ADAPT.Energy} <: AbstractCallback
        threshold::F
        n::Int
    end

    function (stopper::SlowStopper)(
        ::Data, ansatz::AbstractAnsatz, trace::Trace,
        ::AdaptProtocol, ::GeneratorList, ::Observable, ::QuantumState,
    )
        adaptations = trace[:adaptation]
        length(adaptations) < stopper.n && return false

        energies = trace[:energy][:adaptation]  # ENERGIES AT EACH ADAPTATION
        last_n_energies = last(energies, stopper.n)

        energy_range = maximum(last_n_energies) - minimum(last_n_energies)
        if energy_range < stopper.threshold
            ADAPT.set_converged!(ansatz, true)
        end

        return false
    end




    """
        FloorStopper(threshold::Energy, floor::Energy)

    Converge once the energy has gotten close enough to some target value.

    Called for `adapt!` only. Requires a preceding `Tracer(:energy)`.

    # Parameters
    - `threshold`: maximum energy difference before convergence
    - `floor`: the target value

    """
    struct FloorStopper{F<:ADAPT.Energy} <: AbstractCallback
        threshold::F
        floor::F
    end

    function (stopper::FloorStopper)(
        ::Data, ::AbstractAnsatz, trace::Trace,
        ::AdaptProtocol, ::GeneratorList, ::Observable, ::QuantumState,
    )
        last_energy = last(trace[:energy])
        if abs(last_energy - stopper.floor) < stopper.threshold
            ADAPT.set_converged!(ansatz, true)
        end
        return false
    end

end