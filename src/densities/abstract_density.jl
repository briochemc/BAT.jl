# This file is a part of BAT.jl, licensed under the MIT License (MIT).


"""
    abstract type AbstractDensity

Subtypes of `AbstractDensity` must be implement the function

* `DensityInterface.logdensityof(density::SomeDensity, v)`

For likelihood densities this is typically sufficient, since BAT can infer
variate shape and bounds from the prior.

!!! note

    If `DensityInterface.logdensityof` is called with an argument that is out
    of bounds, the behavior is undefined. The result for arguments that are
    not within bounds is *implicitly* `-Inf`, but it is the caller's
    responsibility to handle these cases.

Densities with a known variate shape may also implement

* `ValueShapes.varshape`

Densities with known variate bounds may also implement

* `BAT.var_bounds`

!!! note

    The function `BAT.var_bounds` is not part of the stable public BAT-API,
    it's name and arguments may change without deprecation.
"""
abstract type AbstractDensity end
export AbstractDensity

Base.convert(::Type{AbstractDensity}, density::AbstractDensity) = density
Base.convert(::Type{AbstractDensity}, density::Any) = convert(WrappedNonBATDensity, density)

@inline DensityInterface.DensityKind(::AbstractDensity) = IsDensity()

@inline ValueShapes.varshape(f::Base.Fix1{typeof(DensityInterface.logdensityof),<:AbstractDensity}) = varshape(f.x)
@inline ValueShapes.unshaped(f::Base.Fix1{typeof(DensityInterface.logdensityof),<:AbstractDensity}) = logdensityof(unshaped(f.x))


function ValueShapes.unshaped(density::AbstractDensity, vs::AbstractValueShape)
    varshape(density) <= vs || throw(ArgumentError("Shape of density not compatible with given shape"))
    unshaped(density)
end


"""
    BAT.eval_logval_unchecked(density::AbstractDensity, v::Any)

**DEPRECATED** use/overload `DensityInterface.logdensityof` instead.
"""
const eval_logval_unchecked = logdensityof


show_value_shape(io::IO, vs::AbstractValueShape) = show(io, vs)
function show_value_shape(io::IO, vs::NamedTupleShape)
    print(io, Base.typename(typeof(vs)).name, "(")
    show(io, propertynames(vs))
    print(io, "}(…)")
end

function Base.show(io::IO, d::AbstractDensity)
    print(io, Base.typename(typeof(d)).name, "(objectid = ")
    show(io, objectid(d))
    vs = varshape(d)
    if !ismissing(vs)
        print(io, ", varshape = ")
        show_value_shape(io, vs)
    end
    print(io, ")")
end


"""
    struct DensityEvalException <: Exception

Constructors:

* ```$(FUNCTIONNAME)(func::Function, density::AbstractDensity, v::Any, ret::Any)```

Fields:

$(TYPEDFIELDS)
"""
struct DensityEvalException{F<:Function,D<:AbstractDensity,V,C} <: Exception
    "Density evaluation function that failed."
    func::F

    "Density being evaluated."
    density::D

    "Variate at which the evaluation of `density` (applying `f` to `d` at `v`) failed."
    v::V

    "Cause of failure, either the invalid return value of `f` on `d` at `v`, or another expection (on rethrow)."
    ret::C
end

function Base.showerror(io::IO, err::DensityEvalException)
    print(io, "Density evaluation with $(err.func) failed at ")
    show(io, value_for_msg(err.v))
    if err.ret isa Exception
        print(io, " due to exception ")
        showerror(io, err.ret)
    else
        print(io, ", must not evaluate to ")
        show(io, value_for_msg(err.ret))
    end
    print(io, ", density is ")
    show(io, err.density)
end


"""
    var_bounds(
        density::AbstractDensity
    )::Union{AbstractVarBounds,Missing}

*BAT-internal, not part of stable public API.*

Get the parameter bounds of `density`. See [`AbstractDensity`](@ref) for the
implications and handling of bounds.
"""
var_bounds(density::AbstractDensity) = missing


"""
    ValueShapes.totalndof(density::AbstractDensity)::Union{Int,Missing}

Get the number of degrees of freedom of the variates of `density`. May return
`missing`, if the shape of the variates is not fixed.
"""
function ValueShapes.totalndof(density::AbstractDensity)
    shape = varshape(density)
    ismissing(shape) ? missing : ValueShapes.totalndof(shape)
end


"""
    ValueShapes.varshape(
        density::AbstractDensity
    )::Union{ValueShapes.AbstractValueShape,Missing}

    ValueShapes.varshape(
        density::DistLikeDensity
    )::ValueShapes.AbstractValueShape

Get the shapes of the variates of `density`.

For prior densities, the result must not be `missing`, but may be `nothing` if
the prior only supports unshaped variate/parameter vectors.
"""
ValueShapes.varshape(density::AbstractDensity) = missing


bat_sampler(d::AbstractDensity) = Distributions.sampler(d)


"""
    checked_logdensityof(density::AbstractDensity, v::Any, T::Type{<:Real})

*BAT-internal, not part of stable public API.*

Evaluates density log-value via `DensityInterface.logdensityof` and performs
additional checks.

Throws a `BAT.DensityEvalException` on any of these conditions:

* The variate shape of `density` (if known) does not match the shape of `v`.
* The return value of `DensityInterface.logdensityof` is `NaN`.
* The return value of `DensityInterface.logdensityof` is an equivalent of positive
  infinity.
"""
function checked_logdensityof end

@inline checked_logdensityof(density::AbstractDensity) = Base.Fix1(checked_logdensityof, density)

@inline ValueShapes.varshape(f::Base.Fix1{typeof(checked_logdensityof),<:AbstractDensity}) = varshape(f.x)
@inline ValueShapes.unshaped(f::Base.Fix1{typeof(checked_logdensityof),<:AbstractDensity}) = checked_logdensityof(unshaped(f.x))

@inline DensityInterface.logfuncdensity(f::Base.Fix1{typeof(checked_logdensityof)}) = f.x

function checked_logdensityof(density::AbstractDensity, v::Any)
    check_variate(varshape(density), v)

    logval = try
        logdensityof(density, v)
    catch err
        @rethrow_logged DensityEvalException(logdensityof, density, v, err)
    end

    _check_density_logval(density, v, logval)

    #R = density_valtype(density, v_shaped)
    #return convert(R, logval)::R
    return logval
end

ZygoteRules.@adjoint checked_logdensityof(density::AbstractDensity, v::Any) = begin
    check_variate(varshape(density), v)
    logval, back = try
        ZygoteRules.pullback(logdensityof(density), v)
    catch err
        @rethrow_logged DensityEvalException(logdensityof, density, v, err)
    end
    _check_density_logval(density, v, logval)
    eval_logval_pullback(logval::Real) = (nothing, first(back(logval)))
    (logval, eval_logval_pullback)
end

function _check_density_logval(density::AbstractDensity, v::Any, logval::Real)
    if isnan(logval) || !(logval < float(typeof(logval))(+Inf))
        throw(DensityEvalException(logdensityof, density, v, logval))
    end
    nothing
end


value_for_msg(v::Real) = v
# Strip dual numbers to make errors more readable:
value_for_msg(v::ForwardDiff.Dual) = ForwardDiff.value(v)
value_for_msg(v::AbstractArray) = value_for_msg.(v)
value_for_msg(v::NamedTuple) = map(value_for_msg, v)


"""
    BAT.density_valtype(density::AbstractDensity, v::Any)

*BAT-internal, not part of stable public API.*

Determine a suitable return type for the (log-)density value
of the given density for the given variate.
"""
function density_valtype end

@inline function density_valtype(density::AbstractDensity, v::Any)
    T = float(realnumtype(typeof((v))))
    promote_type(T, default_val_numtype(density))
end

function ChainRulesCore.rrule(::typeof(density_valtype), density::AbstractDensity, v::Any)
    result = density_valtype(density, v)
    _density_valtype_pullback(ΔΩ) = (NoTangent(), NoTangent(), ZeroTangent())
    return result, _density_valtype_pullback
end


"""
    BAT.default_var_numtype(density::AbstractDensity)

*BAT-internal, not part of stable public API.*

Returns the default/preferred underlying numerical type for (elements of)
variates of `density`.
"""
function default_var_numtype end
default_var_numtype(density::AbstractDensity) = Float64


"""
    BAT.default_val_numtype(density::AbstractDensity)

*BAT-internal, not part of stable public API.*

Returns the default/preferred numerical type (log-)density values of
`density`.
"""
function default_val_numtype end
default_val_numtype(density::AbstractDensity) = Float64


"""
    BAT.log_zero_density(T::Type{<:Real})

log-density value to assume for regions of implicit zero density, e.g.
outside of variate/parameter bounds/support.

Returns an equivalent of negative infinity.
"""
log_zero_density(T::Type{<:Real}) = float(T)(-Inf)


"""
    BAT.is_log_zero(x::Real, T::Type{<:Real} = typeof(x)}

*BAT-internal, not part of stable public API.*

Check if x is an equivalent of log of zero, resp. negative infinity,
in respect to type `T`.
"""
function is_log_zero(x::Real, T::Type{<:Real} = typeof(x))
    U = typeof(x)

    FT = float(T)
    FU = float(U)

    x_notnan = !isnan(x)
    x_isinf = !isfinite(x)
    x_isneg = x < zero(x)
    x_notgt1 = !(x > log_zero_density(FT))
    x_notgt2 = !(x > log_zero_density(FU))
    x_iseq1 = x ≈ log_zero_density(FT)
    x_iseq2 = x ≈ log_zero_density(FU)

    x_notnan && ((x_isinf && x_isneg) | x_notgt1 | x_notgt2 | x_iseq1 | x_iseq1)
end



"""
    abstract type DistLikeDensity <: AbstractDensity

A density that implements part of the `Distributions.Distribution` interface.
Such densities are suitable for use as a priors.

Typically, custom priors should be implemented as subtypes of
`Distributions.Distribution`. BAT will automatically wrap them in a subtype of
`DistLikeDensity`.

Subtypes of `DistLikeDensity` are required to support more functionality
than an [`AbstractDensity`](@ref), but less than a
`Distribution{Multivariate,Continuous}`.

A `d::Distribution{Multivariate,Continuous}` can be converted into (wrapped
in) an `DistLikeDensity` via `conv(DistLikeDensity, d)`.

The following functions must be implemented for subtypes:

* `DensityInterface.logdensityof`

* `ValueShapes.varshape`

* `Distributions.sampler`

* `Statistics.cov`

* `BAT.var_bounds`

!!! note

    The function `BAT.var_bounds` is not part of the stable public BAT-API
    and subject to change without deprecation.
"""
abstract type DistLikeDensity <: AbstractDensity end
export DistLikeDensity


"""
    var_bounds(density::DistLikeDensity)::AbstractVarBounds

*BAT-internal, not part of stable public API.*

Get the parameter bounds of `density`. Must not be `missing`.
"""
function var_bounds end


"""
    ValueShapes.totalndof(density::DistLikeDensity)::Int

Get the number of degrees of freedom of the variates of `density`. Must not be
`missing`, a `DistLikeDensity` must have a fixed variate shape.
"""
ValueShapes.totalndof(density::DistLikeDensity) = totalndof(var_bounds(density))



"""
    BAT.AnyDensityLike = Union{...}

Union of all types that BAT will accept as a probability density, resp. that
`convert(AbstractDensity, d)` supports:
    
* [`AbstractDensity`](@ref)
* `DensityInterface.LogFuncDensity`
* `Distributions.Distribution`
"""
const AnyDensityLike = Union{
    AbstractDensity,
    DensityInterface.LogFuncDensity,
    Distributions.ContinuousDistribution
}
export AnyDensityLike


"""
    BAT.AnySampleable = Union{...}

Union of all types that BAT can sample from:

* [`AbstractDensity`](@ref)
* [`DensitySampleVector`](@ref)
* `DensityInterface.LogFuncDensity`
* `Distributions.Distribution`
"""
const AnySampleable = Union{
    AbstractDensity,
    DensitySampleVector,
    DensityInterface.LogFuncDensity,
    Distributions.Distribution
}
export AnySampleable


"""
    BAT.AnyIIDSampleable = Union{...}

Union of all distribution/density-like types that BAT can draw i.i.d.
(independent and identically distributed) samples from:

* [`DistLikeDensity`](@ref)
* `Distributions.Distribution`
"""
const AnyIIDSampleable = Union{
    DistLikeDensity,
    Distributions.Distribution
}
export AnyIIDSampleable



"""
    struct BAT.WrappedNonBATDensity{F<:Base.Callable}

*BAT-internal, not part of stable public API.*

Wraps a log-density function `log_f`.
"""
struct WrappedNonBATDensity{D} <: AbstractDensity
    _d::D

    function WrappedNonBATDensity{D}(density::D) where D
        @argcheck DensityKind(density) isa IsOrHasDensity
        new{D}(density)
    end

    WrappedNonBATDensity(density::D) where D = WrappedNonBATDensity{D}(density)
end

Base.convert(::Type{WrappedNonBATDensity}, density::Any) = WrappedNonBATDensity(density)

@inline Base.parent(density::WrappedNonBATDensity) = density._d

@inline DensityInterface.logdensityof(density::WrappedNonBATDensity, x) = logdensityof(parent(density), x)
@inline DensityInterface.logdensityof(density::WrappedNonBATDensity) = logdensityof(parent(density))

ValueShapes.varshape(density::WrappedNonBATDensity) = varshape(parent(density))

function Base.show(io::IO, density::WrappedNonBATDensity)
    print(io, Base.typename(typeof(density)).name, "(")
    show(io, parent(density))
    print(io, ")")
end
