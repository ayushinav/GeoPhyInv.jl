using Revise
using JuMIT
using Base.Test

# real 1D
x = randn(10,1); α = randn(1); y = α[1] .* x;
J, α1 = JuMIT.Misfits.error_after_scaling(x,y)
@test isapprox(α1.*x, y)
#@test_approx_eq J 0.0

# real 2D
x = randn(10,10); α = randn(1); y = α[1] .* x;
J, α1 = JuMIT.Misfits.error_after_scaling(x,y)
@test isapprox(α1.*x, y)

# complex 2D
x = complex.(randn(10,10), randn(10,10));
α = complex.(randn(1), randn(1)); y = α[1] .* x;
J, α1 = JuMIT.Misfits.error_after_scaling(x,y)
@test isapprox(α1.*x, y)




x = randn(2,2); α = randn(1); y = α[1] .* inv(x);

J = JuMIT.Misfits.error_after_scaling(x,y)
