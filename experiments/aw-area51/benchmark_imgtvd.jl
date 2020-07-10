using ArgParse
using ProximalDistanceAlgorithms
using Images, TestImages, Statistics

global const DIR = joinpath(pwd(), "experiments", "aw-area51", "imgtvd")

# loads common interface + packages
include("common.jl")

function imgtvd_interface(args)
    options = ArgParseSettings(
        prog = "Image Denoising Benchmark",
        description = "Benchmarks proximal distance algorithm for total variation image denoising"
    )

    @add_arg_table! options begin
        "--image"
            help     = "name of test image from TestImages.jl"
            arg_type = String
            required = true
        "--algorithm"
            help     = "choice of algorithm"
            arg_type = Symbol
            required = true
        "--subspace"
            help     = "subspaze size for MMS methods"
            arg_type = Int
            default  = 3
        "--ls"
            help     = "choice of linear solver"
            arg_type = Symbol
            default  = :LSQR
        "--maxiters"
            help     = "maximum iterations"
            arg_type = Int
            default  = 1000
        "--nsamples"
            help     = "samples from @timed."
            arg_type = Int
            default  = 10
        "--accel"
            help     = "toggles Nesterov acceleration"
            action   = :store_true
        "--rtol"
            help     = "relative tolerance on loss"
            arg_type = Float64
            default  = 1e-6
        "--atol"
            help     = "absolute tolerance on distance"
            arg_type = Float64
            default  = 1e-4
        "--rho"
            help     = "initial value for penalty coefficient"
            arg_type = Float64
            default  = 1.0
        "--mu"
            help     = "initial value for step size in ADMM"
            arg_type = Float64
            default  = 1.0
        "--seed"
            help     = "problem randomization seed"
            arg_type = Int64
            default  = 5357
        "--filename"
            help     = "base file name"
            arg_type = String
            default  = ""
    end

    return parse_args(options)
end

function imgtvd_instance(options)
    image = testimage(options["image"])
    noisy = image .+ 0.2 * randn(size(image))
    width, height = size(noisy)
    problem = (input = noisy, ground_truth = image)
    problem_size = (width = width, height = height)

    println("    Image Denoising; $(options["image"]) $(width) × $(height)\n")

    return problem, problem_size
end

function imgtvd_save_results(file, problem, problem_size, solution, cpu_time, memory)
    # compute mean squared error with respect to ground truth
    MSE = mean((solution.output .- problem.ground_truth) .^ 2)

    # save benchmark results
    df = DataFrame(
            width = problem_size.width,
            height  = problem_size.height,
            cpu_time = cpu_time,
            memory   = memory,
            MSE      = MSE
        )
    CSV.write(file, df)

    # get filename without extension
    basefile = splitext(file)[1]

    # save input
    save_array(basefile * ".in", problem.input)

    # save solution
    save_array(basefile * ".out", solution.output)

    return nothing
end

@inline function run_imgtvd(algorithm, problem; kwargs...)
    kw = Dict(kwargs)
    ρ0 = kw["rho"]

    penalty(ρ, n) = min(1e6, ρ0 * 1.1 ^ floor(n/20))

    output = denoise_image_path(algorithm, proble.input; penalty = penalty, kwargs...)

    return (output = output,)
end

# run the benchmark
interface =     imgtvd_interface
run_solver =    run_imgtvd
make_instance = imgtvd_instance
save_results =  imgtvd_save_results

run_benchmark(interface, run_solver, make_instance, save_results, ARGS)
