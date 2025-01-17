# create a timer object, used throughout this package, see TimerOutputs.jl
global const to = TimerOutput();
global const npml = 20

# struct to store FD params that are used in @initialize
mutable struct FD_params
    ndims::Int64 # 2D or 3D
    order::Int64 # stencil order
    use_gpu::Bool # 
    datatype::DataType
end
# default finite-difference stencil order
const _fd = FD_params(2, 2, false, Float32)

"""
Return axis names of 1D, 2D or 3D fields
"""
function dim_names(N, prefix = "", suffix = ""; order = 1)
    if (N == 3)
        names = (order == 2) ? [:zz, :yy, :xx, :xz, :xy, :yz] : [:z, :y, :x]
    elseif (N == 2)
        names = (order == 2) ? [:zz, :xx, :xz] : [:z, :x]
    elseif (N == 1)
        names = [:z]
    else
        error("invalid dim num")
    end
    return [Symbol(prefix, string(m), suffix) for m in names]
end

