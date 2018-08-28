#addprocs(1)
#addprocs(8)
push!(LOAD_PATH,joinpath(@__DIR__))
using Binaries

include("FARCE.jl")
include("MCMC.jl")
using DataFrames
using NLopt
include("Covariation.jl")
using Mapping
include("RankingAndVisualisation.jl")
#using ProfileView
#using GaussianProcesses
#include("BayesianOptimization.jl")
#using BayesianOptimizationCustom
#@everywhere include("InsideParallel.jl")
using Distributions
using Printf
using CommonUtils

using ArgParse
function parse_commandline()
    s = ArgParseSettings()

    @add_arg_table s begin
        "--alignment"
        help = "alignment file to be used"
        arg_type = String
        required = true
        "--tree"
        help = "tree file to be used"
        arg_type = String
        required = false
        "--structure"
        help = "RNA structure to be used"
        arg_type = String
        required = false
        "--numsitecats"
        help = "number of rate categories to be used for site-to-site rate variation"
        arg_type = Int
        default = 3
        "--numlambdacats"
        help = "number of rate categories to be used for base-pair to base-pair rate variation"
        arg_type = Int
        default = 5
        "--outputprefix"
        help = "prefix to be used for outputting results files"
        arg_type = String
        "--maxbasepairdistance"
        help = ""
        arg_type = Int
        default = 100000000
        "--M"
        help = ""
        arg_type = Float64
        default = 1.0
        "--draw"
        help = ""
        action = :store_true
        "--mcmc"
        help = "Perform Bayesian inference using MCMC instead of the default Maximum Likelihood inference"
        action = :store_true
        #=
        "--optimize"
        help = ""
        action = :store_true
        =#
        "--samplesperiter"
        help = ""
        arg_type = Int
        default = 0
        "--maxmcemiter"
        help = ""
        arg_type = Int
        default = 200
        "--shuffle"
        help = ""
        action = :store_true
        "--unpaired"
        help = ""
        action = :store_true
        "--seed"
        help = ""
        arg_type = Int
        default = 15039814119191
        "--cpuonly"
        help = ""
        action = :store_true
        "--fixgu"
        help = ""
        action = :store_true
        "--fixgcau"
        help = ""
        action = :store_true
        "--calcentropy"
        help = ""
        action = :store_true
        "--calcpriorentropy"
        help = ""
        action = :store_true
        "--maxstructure"
        help = ""
        action = :store_true
        "--processmax"
        help = ""
        action = :store_true
        "--lambdazeroweightmin"
        help = ""
        arg_type = Float64
        default = 0.05
        "--bfactor"
        help = ""
        arg_type = Float64
        default = 0.98
        "--numchains"
        help = ""
        arg_type = Int
        default = 1
    end

    return parse_args(s)
end

lambdaweightprior = Beta(2.0,2.0)
function printmatrix(mat::Array{Float64,2})
    ret = ""
    for i=1:size(mat,1)
        ret = string(ret,join(AbstractString[string(@sprintf("%.4f", v)) for v in mat[i,:]], "\t"), "\n")
    end
    return ret
end

function spearmanspvalue(x1::Array{Float64,1}, y1::Array{Float64,1})
    n = length(x1)
    r = corspearman(x1,y1)
    t = r*sqrt((n-2.0)/(1.0-(r*r)))
    p = cdf(TDist(n-2), -abs(t))

    stderr = 1.0 /sqrt(n - 3.0)
    delta = 1.96 * stderr
    lower = tanh(atanh(r) - delta)
    upper = tanh(atanh(r) + delta)
    return r,lower,upper,n,p
end

function spearmanspvalue(paired::Array{Int,1}, x::Array{Float64,1}, y::Array{Float64,1})

    x1 = Float64[]
    y1 = Float64[]
    for i=1:length(x)
        if paired[i] > i
            if !isnan(x[i]) && !isnan(y[i])
                push!(x1, x[i] + randn()*1e-10)
                push!(y1, y[i] + randn()*1e-10)
            end
        end
    end
    println("!!!!", length(x1))
    n = length(x1)
    r = corspearman(x1,y1)
    t = r*sqrt((n-2.0)/(1.0-(r*r)))
    p = cdf(TDist(n-2), -abs(t))

    stderr = 1.0 /sqrt(n - 3.0)
    delta = 1.96 * stderr
    lower = tanh(atanh(r) - delta)
    upper = tanh(atanh(r) + delta)
    #return r,lower,upper,t,p
    return r,lower,upper,n,p
end

function mapstructure(dataset, fastafile, ctfile)
    sequence, pairedsites = readctfile(ctfile)
    mapping, revmapping = createmapping(fastafile, sequence)
    len = length(pairedsites)
    mappedsequence = ""
    mappedpairedsites = zeros(Int,dataset.numcols)
    for i=1:dataset.numcols
        j = get(mapping, i, 0)
        println("A",i,"\t",j)
        if j > 0 && pairedsites[j] > j
            k = get(revmapping, pairedsites[j], 0)
            println("B",pairedsites[j],"\t",k)
            if k > 0
                mappedpairedsites[i] = k
                mappedpairedsites[k] = i
            end
        end

        if j  > 0
            mappedsequence = string(mappedsequence, sequence[j])
        else
            mappedsequence = string(mappedsequence, "-")
        end
    end

    dbnstring = ""
    for i=1:length(mappedpairedsites)
        if mappedpairedsites[i] > i
            dbnstring = string(dbnstring,"(")
        elseif mappedpairedsites[i] == 0
            dbnstring = string(dbnstring,".")
        else
            dbnstring = string(dbnstring,")")
        end
    end
    println(mappedsequence)
    println(dbnstring)

    return mappedsequence,mappedpairedsites, mapping, revmapping
end

function getZ(params::Array{Float64,1}, dataset::Dataset, siteCats::Int=3, lambdaCats::Int=5, usecuda::Bool=true,unpaired::Bool=true)
    #tic()
    currentparams = getparams(params,dataset,siteCats,lambdaCats,0)
    if unpaired
        currentparams.lambdaratesGC = zeros(Float64, length(currentparams.lambdaratesGT))
        currentparams.lambdaratesAT = zeros(Float64, length(currentparams.lambdaratesGT))
        currentparams.lambdaratesGT = zeros(Float64, length(currentparams.lambdaratesGT))
    end

    grammar = KH99()
    unpairedlogprobs = computeunpairedlikelihoods(dataset, currentparams)
    maxbasepairdistance = 1000000
    pairedlogprobs, ret = coevolutionall(dataset,currentparams,true,false,true,maxbasepairdistance,usecuda)
    #elapsed = toc()
    #println("P1\t", elapsed)
    maskgapped!(pairedlogprobs,dataset.gapfrequency,0.5,-Inf)
    #tic()
    ll = computeinsideKH99(unpairedlogprobs, pairedlogprobs, 1.0,true,usecuda)
    #elapsed = toc()
    #println("P2\t", elapsed)
    return ll
end


maxll = -1e20
maxparams = []
optiter = 0
function modellikelihood(params::Array{Float64,1}, dataset::Dataset, paired::Array{Int,1}, siteCats::Int=3, lambdaCats::Int=5, fixGU::Bool=false, fixGCAU::Bool=false, integratestructure::Bool=true, unpairedmodel::Bool=false, maxfile=nothing, usecuda::Bool=true)
    global maxll
    global maxparams
    global optiter
    optiter += 1

    ll = -1e20
    currentparams = getparams(params,dataset,siteCats,lambdaCats,0,fixGU,fixGCAU)

    if fixGU
        currentparams.lambdaratesGT = zeros(Float64, length(currentparams.lambdaratesGT))
    end
    if fixGCAU
        currentparams.lambdaratesGC = currentparams.lambdaratesAT
    end
    if unpairedmodel
        currentparams.lambdaratesGC = zeros(Float64, length(currentparams.lambdaratesGT))
        currentparams.lambdaratesAT = zeros(Float64, length(currentparams.lambdaratesGT))
        currentparams.lambdaratesGT = zeros(Float64, length(currentparams.lambdaratesGT))
    end

    try
        if integratestructure
            grammar = KH99()
            unpairedlogprobs = computeunpairedlikelihoods(dataset, currentparams)
            #tic()
            maxbasepairdistance = 1000000
            pairedlogprobs, ret = coevolutionall(dataset,currentparams,true,false,true,maxbasepairdistance,usecuda)
            maskgapped!(pairedlogprobs,dataset.gapfrequency,0.5,-Inf)
            ll = computeinsideKH99(unpairedlogprobs, pairedlogprobs, 1.0, true, usecuda)
            #elapsed = toc();
            #println("Iteration ", optiter, ", elapsed: ", elapsed)
            println("Iteration ", optiter)
        else
            maxbasepairdistance = 1000000
            ll = computetotallikelihood(MersenneTwister(5043820111),dataset, currentparams, paired,false,true,false,1.0,false, maxbasepairdistance, usecuda)
        end

        if !unpairedmodel
            ll += logpdf(lambdaweightprior, params[15])
        else
            ll += logpdf(lambdaweightprior, 0.5)
        end

        savemaximum(ll, params, maxfile)
    catch e
        println("Exception")
        println(catch_backtrace())
        println(e)
        return ll
    end

    if isnan(ll) || isinf(ll)
        return -1e20
    end
    if sum(params[12:14]) >= 1.0
        return -1e20
    end

    if ll > maxll
        maxll = ll
        maxparams = params

        ret = "Maximum\t"
        ret = string(ret, maxll, "\t")
        ret = string(ret, @sprintf("%d", optiter), "\t")
        for x in maxparams
            ret = string(ret, @sprintf("%0.2f", x), "\t")
        end
        println(ret)
    end
    return ll
end


function freqconstraint(x::Array{Float64,1})
    return (x[12] + x[13] + x[14] - 1.0)
    #return 1.0 - (x[12] + x[13] + x[14])
end


function computesamplelikelihoods(params::ModelParameters, dataset::Dataset, structures::Array{Array{Int,1},1})
    total = -Inf
    museparams = getmusespecificparamsarray(params)
    len = params.siteCats*params.siteCats*length(params.lambdaratesGC)
    cache = FastCache[FastCache(250000,16) for i=1:len]
    unpairedcache = FastCache[FastCache(100000,4) for i=1:params.siteCats]
    unpairedcolumncache = ColumnCache(100000)
    pairedcolumncache = ColumnCache(1000000)
    likelihoods = Float64[]
    for paired in structures
        ll = calculatecachedlikelihood(dataset, params, museparams, params.states, paired, cache, unpairedcache, true,unpairedcolumncache,pairedcolumncache)
        push!(likelihoods, ll)
    end
    return likelihoods
end

#=
function computesamplelikelihoods(params::ModelParameters, dataset::Dataset, structures::Array{Array{Int,1},1})
likelihoods = SharedArray(Float64,length(structures))

numthreads = 8
blocks = Array{Tuple{Int,Array{Int,1}},1}[Tuple{Int,Array{Int,1}}[] for p=1:numthreads]
for i=1:length(structures)
push!(blocks[(i-1) % numthreads+1], (i,structures[i]))
end

museparams = getmusespecificparamsarray(params)
len = params.siteCats*params.siteCats*length(params.lambdarates)

@sync @parallel for block in blocks
cache = FastCache[FastCache(250000,16) for i=1:len]
unpairedcache = FastCache[FastCache(100000,4) for i=1:params.siteCats]
unpairedcolumncache = ColumnCache(100000)
pairedcolumncache = ColumnCache(1000000)
for structurepair in block
i = structurepair[1]
paired = structurepair[2]
likelihoods[i] = calculatecachedlikelihood(dataset, params, museparams, params.states, paired, cache, unpairedcache, true, unpairedcolumncache, pairedcolumncache)
end
end
return likelihoods
end=#

function computeimportanceratio(currentlikelihoods, params::Array{Float64,1}, dataset::Dataset, structures::Array{Array{Int,1},1}, siteCats::Int=3, lambdaCats::Int=5, fixGU::Bool=false,fixGCAU::Bool=false)
    println("X", params)
    global maxll
    global maxparams
    global optiter
    optiter += 1

    #tic()

    llsum = -Inf
    if sum(params[12:14]) >= 0.99 || params[10] < 0.0 || params[11] < 0.0
        return -1e20
    end
    freqs = Float64[params[12],params[13],params[14],1.0 - sum(params[12:14])]
    freqs /= sum(freqs)

    proposedparams = getparams(params,dataset,siteCats,lambdaCats,0,fixGU,fixGCAU)
    if fixGU
        proposedparams.lambdaratesGT = zeros(Float64, length(proposedparams.lambdaratesGT))
    end
    if fixGCAU
        proposedparams.lambdaratesGC = proposedparams.lambdaratesAT
    end
    proposedlikelihoods = computesamplelikelihoods(proposedparams, dataset, structures)

    count = 0
    for (currentll, proposedll) in zip(currentlikelihoods, proposedlikelihoods)
        llsum = CommonUtils.logsumexp(llsum, proposedll-currentll)
        count += 1
    end
    #println(llsum, "\t", log(count))
    llsum = llsum - log(count)
    #println("Importance ratio=", llsum)

    if isnan(llsum) || isinf(llsum)
        return -1e20
    end

    if llsum > maxll
        maxll = llsum
        maxparams = params
        #println("Maximum\t",maxll,"\t",optiter,"\t", maxparams)
        ret = "Maximum\t"
        ret = string(ret, maxll, "\t")
        #ret = string(ret, @sprintf("%0.2f", maxll), "\t")
        ret = string(ret, @sprintf("%d", optiter), "\t")
        for x in maxparams
            ret = string(ret, @sprintf("%0.2f", x), "\t")
        end
        println(ret)
        currentparams = getparams(params,dataset,siteCats,lambdaCats,0,fixGU,fixGCAU)
        if fixGU
            currentparams.lambdaratesGT = zeros(Float64, length(currentparams.lambdaratesGT))
        end
        if fixGCAU
            currentparams.lambdaratesGC = currentparams.lambdaratesAT
        end
        #=
        meanlambdaGC = sum((currentparams.lambdaratesGC+1.0).*currentparams.lambdaweightsGC)
        meanlambdaAT = sum((currentparams.lambdaratesAT+1.0).*currentparams.lambdaweightsAT)
        meanlambdaGT = sum((currentparams.lambdaratesGT+1.0).*currentparams.lambdaweightsGT)
        meanlambdaGC2 = sum((currentparams.lambdaratesGC[2:end]).*currentparams.lambdaweightsGC[2:end])/sum(currentparams.lambdaweightsGC[2:end])
        meanlambdaAT2 = sum((currentparams.lambdaratesAT[2:end]).*currentparams.lambdaweightsAT[2:end])/sum(currentparams.lambdaweightsAT[2:end])
        meanlambdaGT2 = sum((currentparams.lambdaratesGT[2:end]).*currentparams.lambdaweightsGT[2:end])/sum(currentparams.lambdaweightsGT[2:end])
        println("BmeanlambdaGC", meanlambdaGC,"\t", meanlambdaGC2,"\t", currentparams.lambdaGammaShapeGC, "\t", currentparams.lambdaGammaScaleGC, "\t", currentparams.lambdaratesGC)
        println("BmeanlambdaAT", meanlambdaAT,"\t", meanlambdaAT2,"\t", currentparams.lambdaGammaShapeAT, "\t", currentparams.lambdaGammaScaleAT, "\t", currentparams.lambdaratesAT)
        println("BmeanlambdaGT", meanlambdaGT,"\t", meanlambdaGT2,"\t", currentparams.lambdaGammaShapeGT, "\t", currentparams.lambdaGammaScaleGT, "\t", currentparams.lambdaratesGT)=#
    end
    #toc()
    return llsum
end

maximumZ = -Inf
function savemaximum(Z::Float64, maxparams::Array{Float64,1}, maxfile, override::Bool=false, statuslabel::String="")
    global maximumZ
    maximumparams = maxparams

    if isfile(maxfile)
        jsondict = JSON.parsefile(maxfile)
        if Z > jsondict["Z"] || override
            if Z > maximumZ  || override
                maximumZ = Z
                jsondict["Z"] = maximumZ
                jsondict["maxparams"] = maxparams
                jsondict["status"] = statuslabel
                maximumparams = jsondict["maxparams"]
                out = open(maxfile,"w")
                ret = replace(JSON.json(jsondict),",\"" => ",\n\"")
                ret = replace(ret, "],[" => "],\n[")
                ret = replace(ret, "{" => "{\n")
                ret = replace(ret, "}" => "\n}")
                write(out,ret)
                close(out)
            end
        end
    elseif Z > maximumZ || override
        maximumZ = Z
        jsondict = Dict()
        jsondict["Z"] = maximumZ
        jsondict["maxparams"] = maxparams
        jsondict["status"] = statuslabel
        maximumparams = jsondict["maxparams"]
        out = open(maxfile,"w")
        ret = replace(JSON.json(jsondict),",\"" => ",\n\"")
        ret = replace(ret, "],[" => "],\n[")
        ret = replace(ret, "{" => "{\n")
        ret = replace(ret, "}" => "\n}")
        write(out,ret)
        close(out)
    end

    return maximumZ, maximumparams
end


function optimizesamplelikelihood(rng::AbstractRNG, initialparams::Array{Float64,1}, dataset::Dataset, siteCats::Int=3, lambdaCats::Int=5, fixGU::Bool=false, fixGCAU::Bool=false, fixLambdaWeight::Bool=true, unpairedmodel::Bool=false,maxoptiter::Int=1000,samplesperiter::Int=50,maxbasepairdistance::Int=500, maxfile=nothing, usecuda::Bool=true)
    global maxll
    maxll = -1e20
    if unpairedmodel
        initialparams[1] = 1.0
        initialparams[2] = 1.0
        initialparams[3] = 1.0
        #initialparams[10] = 1.0
    end
    if fixGU
        initialparams[3] = 1.0
    end
    if fixLambdaWeight
        initialparams[15] = 0.5
    end
    initialparams[15] = max(0.0001, initialparams[15])

    currentparams = getparams(initialparams,dataset,siteCats,lambdaCats,0,fixGU,fixGCAU)
    if fixGU
        currentparams.lambdaratesGT = zeros(Float64, length(currentparams.lambdaratesGT))
    end
    if fixGCAU
        currentparams.lambdaratesGC = currentparams.lambdaratesAT
    end

    grammar = KH99()
    unpairedlogprobs = computeunpairedlikelihoods(dataset, currentparams)
    #tic()
    pairedlogprobs, ret = coevolutionall(dataset,currentparams,true,false,true,maxbasepairdistance, usecuda)
    #println("unpairedlogprobs",unpairedlogprobs)
    #println("pairedlogprobs",pairedlogprobs)
    #elapsed = toc()
    #println("P1\t", elapsed)
    maskgapped!(pairedlogprobs,dataset.gapfrequency,0.5,-Inf)

    #tic()
    inside = computeinsideKH99(unpairedlogprobs, pairedlogprobs, 1.0, false, usecuda)
    #toc()
    Z = inside[1,1,dataset.numcols]
    if maxfile != nothing
        savemaximum(Z,initialparams,maxfile, false, "Optimisation incomplete")
    end


    structures = Array{Int,1}[]
    for i=1:samplesperiter
        paired = zeros(Int,dataset.numcols)
        samplestructure(rng, inside, pairedlogprobs, unpairedlogprobs, 1, dataset.numcols, paired, grammar, 1.0)
        push!(structures,paired)
    end
    currentlikelihoods = computesamplelikelihoods(currentparams, dataset, structures)

    opt = Opt(:LN_NELDERMEAD, 20)
    #opt = Opt(:LN_COBYLA, 20)
    localObjectiveFunction = ((param, grad) -> computeimportanceratio(currentlikelihoods, param, dataset, structures, siteCats, lambdaCats, fixGU, fixGCAU))
    lower = ones(Float64, 20)*0.0001
    lower[1] = 1.0
    lower[2] = 1.0
    lower[3] = 1.0
    #lower[10] = 0.0001
    lower[10] = 1.0 #GC
    lower[11] = 0.0001
    lower[12] = 0.01
    lower[13] = 0.01
    lower[14] = 0.01
    lower[15] = 0.0001
    if unpairedmodel
        lower[10] = 1.0
        lower[15] = 0.5
        #lower[11] = 1.0
    end
    lower[16] = 0.0001
    #lower[17] = 0.0001
    lower[17] = 1.0 # AT
    lower[18] = 0.0001
    lower[19] = 1.0 # GT
    #lower[19] = 0.0001
    lower[20] = 0.0001

    if fixLambdaWeight
        lower[15] = 0.5
    end
    lower_bounds!(opt, lower)

    upper = ones(Float64, 20)*50.0
    upper[1] = 1.0
    upper[2] = 1.0
    upper[3] = 1.0
    upper[12] = 2.0
    upper[13] = 2.0
    upper[14] = 2.0
    upper[15] = 0.9999
    upper[16] = 250.0
    if unpairedmodel
        upper[1] = 1.0
        upper[2] = 1.0
        upper[3] = 1.0
        upper[10] = 1.0
        upper[15] = 0.5
        #upper[11] = 1.0
    end

    if fixLambdaWeight
        upper[15] = 0.5
    end
    if fixGU
        upper[3] = lower[3]
        upper[19] = lower[19]
    end
    if fixGCAU
        upper[2] = lower[2]
        upper[10] = lower[10] # GC
    end
    #ZZZZZZZZZZZZZZZZZZ
    upper[18] = 0.0001
    upper[20] = 0.0001
    upper_bounds!(opt, upper)

    xtol_rel!(opt,1e-5)
    maxeval!(opt, maxoptiter)
    max_objective!(opt, localObjectiveFunction)


    (minf,minx,ret) = optimize(opt, initialparams)
    return minx, initialparams, Z + logpdf(lambdaweightprior, minx[15])
end

function mcem(dataset::Dataset, siteCats::Int=3, lambdaCats::Int=5, fixGU::Bool=false, fixGCAU::Bool=false, unpairedmodel::Bool=false,maxoptiter::Int=1000,samplesperiter::Int=50,maxbasepairdistance::Int=500, initparams::ModelParameters=nothing, maxfile=nothing, usecuda::Bool=true)
    global maxll
    maxll = -1e20
    fixLambdaWeight = false
    initialparams = 2.0*ones(Float64,20)
    if initialparams == nothing
        initialparams[1] = 1.5
        initialparams[2] = 1.5
        initialparams[3] = 1.5
        initialparams[12] = dataset.obsfreqs[1]
        initialparams[13] = dataset.obsfreqs[2]
        initialparams[14] = dataset.obsfreqs[3]
        initialparams[15] = 0.5
        initialparams[1] = 1.0
        initialparams[2] = 1.0
        initialparams[3] = 1.0
    else
        initialparams = getparamsvector(initparams)
    end

    #=
    if fixGU
    initialparams[3] = 1.0
end
if fixGCAU
initialparams[2] = initialparams[1]
end=#
if fixLambdaWeight
    initialparams[15] = 0.5
end

initialparams[15] = max(0.0001, initialparams[15])

rng = MersenneTwister(757494371317)
maxZ = -1e20
maxparams = nothing
noimprovement = 0
for i=1:maxoptiter
    initialparams, params, Z = optimizesamplelikelihood(rng, initialparams, dataset, siteCats, lambdaCats, fixGU, fixGCAU, fixLambdaWeight, unpairedmodel, 150,samplesperiter,maxbasepairdistance, maxfile, usecuda)
    if Z > maxZ
        maxZ = Z
        maxparams = copy(params)
        noimprovement = 0
    else
        noimprovement += 1
    end
    println(i,"\t",maxZ,"\t", noimprovement,"\t", maxparams)

    if noimprovement >= 3
        break
    end
end

return getparams(maxparams, dataset, siteCats, lambdaCats,0,fixGU,fixGCAU)
end

function shufflealignment(rng::AbstractRNG, fastafile, outputfile)
    sequences = AbstractString[]
    names = AbstractString[]

    FastaIO.FastaReader(fastafile) do fr
        for (desc, seq) in fr
            len = length(seq)
            push!(names,desc)
            push!(sequences, seq)
        end
    end

    columnindices = Int[i for i=1:length(sequences[1])]
    shuffle!(rng, columnindices)

    newsequences = AbstractString[]
    for seq in sequences
        newseq = ""
        for col in columnindices
            newseq = string(newseq, seq[col])
        end
        push!(newsequences, newseq)
    end

    fout = open(outputfile, "w")
    seqindex = 1
    for seq in newsequences
        write(fout, string(">seq", seqindex, "\n"))
        write(fout, string(seq, "\n"))
        seqindex += 1
    end
    close(fout)
    return outputfile
end

function maskarraysel(arr::Array{Float64,1}, sel::Array{Int,1})
    outarr = Float64[]
    for s in sel
        push!(outarr, arr[s])
    end
    return outarr
end

function maskarraysel(arr::Array{StepRangeLen{Float64},1}, sel::Array{Int,1})
    outarr = StepRangeLen{Float64}[]
    for s in sel
        push!(outarr, arr[s])
    end
    return outarr
end

function unmaskarraysel(arr::Array{Float64,1}, sel::Array{Int,1}, len::Int)
    outarr = zeros(Float64,len)
    i = 1
    for s in sel
        outarr[s] =  arr[i]
        i += 1
    end
    return outarr
end

function optimizemodel(dataset::Dataset, pairedsites::Array{Int,1}, siteCats::Int=3, lambdaCats::Int=5, fixGU::Bool=false, fixGCAU::Bool=false, integratestructure::Bool=true, unpairedmodel::Bool=false,maxoptiter::Int=1000, initparams::ModelParameters=nothing, maxfile=nothing, usecuda::Bool=true)
    global maxll
    maxll = -1e20
    fixLambdaWeight = false
    initialparams = 2.0*ones(Float64,20)
    if initialparams == nothing
        initialparams[1] = 1.5
        initialparams[2] = 1.5
        initialparams[3] = 1.5
        initialparams[12] = dataset.obsfreqs[1]
        initialparams[13] = dataset.obsfreqs[2]
        initialparams[14] = dataset.obsfreqs[3]
        initialparams[15] = 0.5
        initialparams[1] = 1.0
        initialparams[2] = 1.0
        initialparams[3] = 1.0
    else
        initialparams = getparamsvector(initparams)
    end

    paired = copy(pairedsites)
    if unpairedmodel
        fill!(paired, 0)
    end
    localObjectiveFunction = ((param, grad) -> modellikelihood(param, dataset, paired, siteCats, lambdaCats, fixGU, fixGCAU, integratestructure, unpairedmodel, maxfile, usecuda))
    opt = Opt(:LN_NELDERMEAD, 20)
    #opt = Opt(:LN_COBYLA, 20)

    #opt = Opt(:LN_NELDERMEAD, 15)
    #opt = Opt(:GN_ISRES, 20)
    lower = ones(Float64, 20)*0.0001
    lower[1] = 1.0
    lower[2] = 1.0
    lower[3] = 1.0
    #lower[10] = 0.0001
    lower[10] = 1.0 #GC
    lower[11] = 0.0001
    lower[12] = 0.01
    lower[13] = 0.01
    lower[14] = 0.01
    lower[15] = 0.0001
    if unpairedmodel
        lower[10] = 1.0
        lower[15] = 0.5
        #lower[11] = 1.0
    end
    lower[16] = 0.0001
    #lower[17] = 0.0001
    lower[17] = 1.0 # AT
    lower[18] = 0.0001
    lower[19] = 1.0 # GT
    #lower[19] = 0.0001
    lower[20] = 0.0001

    if fixLambdaWeight
        lower[15] = 0.5
    end
    lower_bounds!(opt, lower)

    upper = ones(Float64, 20)*50.0
    upper[1] = 1.0
    upper[2] = 1.0
    upper[3] = 1.0
    upper[12] = 2.0
    upper[13] = 2.0
    upper[14] = 2.0
    upper[15] = 0.9999
    upper[16] = 250.0
    if unpairedmodel
        upper[1] = 1.0
        upper[2] = 1.0
        upper[3] = 1.0
        upper[10] = 1.0
        upper[15] = 0.5
        #upper[11] = 1.0
    end

    if fixLambdaWeight
        upper[15] = 0.5
    end
    if fixGU
        upper[3] = 1.0
    end
    #ZZZZZZZZZZZZZZZZZZ
    upper[18] = 0.0001
    upper[20] = 0.0001
    upper_bounds!(opt, upper)

    xtol_rel!(opt,1e-5)
    maxeval!(opt, maxoptiter)

    max_objective!(opt, localObjectiveFunction)

    if unpairedmodel
        initialparams[1] = 1.0
        initialparams[2] = 1.0
        initialparams[3] = 1.0
        initialparams[10] = 1.0
    end
    if fixGU
        initialparams[3] = 1.0
    end
    if fixLambdaWeight
        initialparams[15] = 0.5
    end
    initialparams[15] = max(0.0001, initialparams[15])
    (minf,minx,ret) = optimize(opt, initialparams)
    println(minf,minx,ret)

    if unpairedmodel
        if integratestructure
            ll = getZ(minx, dataset, siteCats, lambdaCats, usecuda, true)
            savemaximum(ll, minx, maxfile, true, string("Optimisation complete: ", ret))
        else
            savemaximum(minf, minx, maxfile, true, string("Optimisation complete: ", ret))
        end
    end
    println("Complete")

    return getparams(minx, dataset, siteCats, lambdaCats,0,fixGU,fixGCAU)
end

function cleandataset(fastafile, outputfile)
    names = []
    sequences = []
    seqnametoindex  = Dict{AbstractString,Int}()
    FastaIO.FastaReader(fastafile) do fr
        seqindex = 1
        for (desc, seq) in fr
            len = length(seq)
            push!(names,desc)
            push!(sequences, seq)
            seqnametoindex[desc] = seqindex
            seqindex += 1
        end
    end

    #outfilename = string(outputdir, fastafile, ".norm")
    fout = open(outputfile, "w")
    seqindex = 1
    for seq in sequences
        write(fout, string(">seq", seqindex, "\n"))
        write(fout, string(uppercase(seq), "\n"))
        seqindex += 1
    end
    close(fout)
    return outputfile
end

function processmax2(maxfile::AbstractString, dataset::Dataset, params::ModelParameters, maxbasepairdistance::Int, usecuda::Bool, unpaired::Bool)
    siteloglikelihoods = nothing
    if 1 == 2
        if usecuda
            siteloglikelihoods = felsensteinposteriorsiterateconditionalscuda(unpairedposteriorprobs, pairedposteriorprobs,dataset, params, getmusespecificparamsarray(params))
        else
            siteloglikelihoods = getposteriorsiterates(unpairedposteriorprobs, pairedposteriorprobs, dataset, params, unpaired)
        end

        fout = open(string(maxfile, ".siterates.csv"),"w")
        pairingstr = ""
        if !parsed_args["unpaired"]
            pairingstr = string(",\"pairing probability\"")
        end
        println(fout, join(AbstractString[string("\"rate=", @sprintf("%.3f", siteRate), "\"") for siteRate in  currentparams.siteRates],","),",\"Mean\"", pairingstr)
        for i=1:dataset.numcols
            siteposteriorprobs = zeros(Float64, currentparams.siteCats)
            total = -Inf
            for siteCat=1:currentparams.siteCats
                siteposteriorprobs[siteCat] = siteloglikelihoods[siteCat, i]
                total = CommonUtils.logsumexp(total, siteposteriorprobs[siteCat])
            end
            siteposteriorprobs = exp.(siteposteriorprobs-total)
            pairingstr = ""
            if !parsed_args["unpaired"]
                pairingstr = string(",", 1.0 - unpairedposteriorprobs[i])
            end
            println(fout, join(AbstractString[string("\"", siteposteriorprobs[siteCat], "\"") for siteCat=1:currentparams.siteCats], ","),",", sum(siteposteriorprobs.*currentparams.siteRates), pairingstr)
        end
        close(fout)
    end

    if !unpaired
        unpairedlogprobs = computeunpairedlikelihoods(dataset, params)
        pairedlogprobs, ret = coevolutionall(dataset,params,true,false,true,maxbasepairdistance,usecuda)

        mapping = zeros(Int,dataset.numcols)
        revmapping = zeros(Int, dataset.numcols)
        cutoff = 0.5
        index = 1
        for i=1:dataset.numcols
            if dataset.gapfrequency[i] < cutoff
                mapping[i] = index
                revmapping[index] = i
                index += 1
            end
        end
        newlen = index - 1

        unpairedlogprobs_trunc = ones(Float64, newlen)*-Inf
        pairedlogprobs_trunc = ones(Float64, newlen, newlen)*-Inf
        for i=1:dataset.numcols
            if mapping[i] > 0
                unpairedlogprobs_trunc[mapping[i]] = unpairedlogprobs[i]
                for j=1:dataset.numcols
                    if mapping[j] > 0
                        pairedlogprobs_trunc[mapping[i],mapping[j]] = pairedlogprobs[i,j]
                    end
                end
            end
        end
        inside = computeinsideKH99(unpairedlogprobs_trunc, pairedlogprobs_trunc, 1.0,false,usecuda)
        outside = computeoutsideKH99(inside,unpairedlogprobs_trunc, pairedlogprobs_trunc, usecuda)
        unpairedposteriorprobs_trunc,pairedposteriorprobs_trunc = computebasepairprobs(inside, outside, unpairedlogprobs_trunc, pairedlogprobs_trunc, KH99())
        paired_trunc = getPosteriorDecodingConsensusStructure(pairedposteriorprobs_trunc, unpairedposteriorprobs_trunc, usecuda)

        paired = zeros(Int, dataset.numcols)
        for i=1:dataset.numcols
            if mapping[i] > 0
                if paired_trunc[mapping[i]] > 0
                    paired[i] = revmapping[paired_trunc[mapping[i]]]
                end
            end
        end
        consensus = copy(paired)
        unpairedposteriorprobs = zeros(Float64, dataset.numcols)
        pairedposteriorprobs = zeros(Float64, dataset.numcols, dataset.numcols)
        for i=1:dataset.numcols
            if mapping[i] > 0
                unpairedposteriorprobs[i] = unpairedposteriorprobs_trunc[mapping[i]]
                for j=1:dataset.numcols
                    if mapping[j] > 0
                        pairedposteriorprobs[i,j] = pairedposteriorprobs_trunc[mapping[i],mapping[j]]
                    end
                end
            end
        end

        #inside = computeinsideKH99(unpairedlogprobs, pairedlogprobs, 1.0,false,usecuda)
        #outside = computeoutsideKH99(inside,unpairedlogprobs, pairedlogprobs, usecuda)
        #unpairedposteriorprobs,pairedposteriorprobs = computebasepairprobs(inside, outside, unpairedlogprobs, pairedlogprobs, KH99())
        fout = open(string(maxfile, ".posteriorunpaired"),"w")
        println(fout,unpairedposteriorprobs)
        close(fout)
        fout = open(string(maxfile, ".posteriorpaired"),"w")
        println(fout,printmatrix(pairedposteriorprobs))
        close(fout)

        ematrix = nothing
        smatrix = nothing
        #consensus = getPosteriorDecodingConsensusStructure(pairedposteriorprobs, unpairedposteriorprobs, usecuda)
        fout = open(string(maxfile, ".consensus.dbn"),"w")
        println(fout, getdotbracketstring(consensus))
        close(fout)
        writectfile(consensus, repeat("N", length(consensus)), string(maxfile, ".consensus.ct"))

        pairedlogprobs, ret = coevolutionall(dataset,params,true,true,true,maxbasepairdistance,usecuda)

        museparams = getmusespecificparamsarray(params)
        posteriorcoevolving = zeros(Float64, dataset.numcols, dataset.numcols)
        posteriormeanlambda = zeros(Float64, dataset.numcols, dataset.numcols)
        bayesfactorcoevolving = zeros(Float64, dataset.numcols, dataset.numcols)
        for i=1:dataset.numcols
            posteriorcoevolving[i,i] = 0.0
            for j=i+1:dataset.numcols
                posteriormeanlambda[i,j] = 0.0
                for k=1:length(museparams)
                    posteriormeanlambda[i,j] += museparams[k].lambdarate*exp(ret[k][i,j]-pairedlogprobs[i,j])
                    posteriormeanlambda[j,i] = posteriormeanlambda[i,j]
                    #println(k,"\t",ret[k][i,j],"\t",pairedlogprobs[i,j], "\t", exp(ret[k][i,j]-pairedlogprobs[i,j]))
                end
                postprob = exp(ret[1][i,j]-pairedlogprobs[i,j])
                bf = (postprob/(1.0-postprob))/(params.lambdazeroweight/(1.0-params.lambdazeroweight))
                bayesfactorcoevolving[i,j] = 1.0/bf
                bayesfactorcoevolving[j,i] = 1.0/bf
                posteriorcoevolving[i,j] = 1.0 - exp(ret[1][i,j]-pairedlogprobs[i,j])
                posteriorcoevolving[j,i] = posteriorcoevolving[i,j]
            end
        end
        fout = open(string(maxfile, ".consensus.bp"),"w")
        for i=1:length(consensus)
            bp = "-\t-\t-\t-"
            if consensus[i] > 0
                #println(pairedposteriorprobs[i,consensus[i]])
                #println(posteriorcoevolving[i,consensus[i]])
                #println(bayesfactorcoevolving[i,consensus[i]])
                #println(posteriormeanlambda[i,consensus[i]])
                bp = string(@sprintf("%.4f", pairedposteriorprobs[i,consensus[i]]), "\t", @sprintf("%.4f", posteriorcoevolving[i,consensus[i]]), "\t", @sprintf("%.4e", bayesfactorcoevolving[i,consensus[i]]), "\t", @sprintf("%.4f", posteriormeanlambda[i,consensus[i]]))
            end
            println(fout, i,"\t", consensus[i], "\t", @sprintf("%.4f", unpairedposteriorprobs[i]), "\t", bp, "\t", @sprintf("%.4f", maximum(pairedposteriorprobs[i,:])))
        end
        close(fout)
        cutoff = 0.001
        fout = open(string(maxfile,"_", cutoff, ".csv"),"w")
        println(fout, "\"i\",\"j\",\"paired(i)\",\"paired(j)\",\"paired(i,j)\",\"p(lambda>0)\",\"meanlambda\",\"bayesfactor(lambda>0)\"")
        for i=1:dataset.numcols
            for j=i+1:dataset.numcols
                if pairedposteriorprobs[i,j] >= cutoff
                    println(fout,"\"",i,"\",\"",j,"\",\"",1.0-unpairedposteriorprobs[i],"\",\"",1.0-unpairedposteriorprobs[j],"\",\"",pairedposteriorprobs[i,j],"\",\"",posteriorcoevolving[i,j],"\",\"",posteriormeanlambda[i,j],"\",\"",bayesfactorcoevolving[i,j],"\"")
                end
            end
        end
        close(fout)


        fout = open(string(maxfile, ".posteriorcoevolving"),"w")
        println(fout,printmatrix(posteriorcoevolving))
        close(fout)
        fout = open(string(maxfile, ".posteriormeanlambda"),"w")
        println(fout,printmatrix(posteriormeanlambda))
        close(fout)
        fout = open(string(maxfile, ".bayesfactorcoevolving"),"w")
        println(fout,printmatrix(bayesfactorcoevolving))
        close(fout)
    end
end

function processmax(outputprefix, alignmentfile, maxfile::AbstractString, dataset::Dataset, params::ModelParameters, maxbasepairdistance::Int, usecuda::Bool, unpaired::Bool)
    siteloglikelihoods = nothing
    if 1 == 2
        if usecuda
            siteloglikelihoods = felsensteinposteriorsiterateconditionalscuda(unpairedposteriorprobs, pairedposteriorprobs,dataset, params, getmusespecificparamsarray(params))
        else
            siteloglikelihoods = getposteriorsiterates(unpairedposteriorprobs, pairedposteriorprobs, dataset, params, unpaired)
        end

        fout = open(string(maxfile, ".siterates.csv"),"w")
        pairingstr = ""
        if !parsed_args["unpaired"]
            pairingstr = string(",\"pairing probability\"")
        end
        println(fout, join(AbstractString[string("\"rate=", @sprintf("%.3f", siteRate), "\"") for siteRate in  currentparams.siteRates],","),",\"Mean\"", pairingstr)
        for i=1:dataset.numcols
            siteposteriorprobs = zeros(Float64, currentparams.siteCats)
            total = -Inf
            for siteCat=1:currentparams.siteCats
                siteposteriorprobs[siteCat] = siteloglikelihoods[siteCat, i]
                total = CommonUtils.logsumexp(total, siteposteriorprobs[siteCat])
            end
            siteposteriorprobs = exp.(siteposteriorprobs-total)
            pairingstr = ""
            if !parsed_args["unpaired"]
                pairingstr = string(",", 1.0 - unpairedposteriorprobs[i])
            end
            println(fout, join(AbstractString[string("\"", siteposteriorprobs[siteCat], "\"") for siteCat=1:currentparams.siteCats], ","),",", sum(siteposteriorprobs.*currentparams.siteRates), pairingstr)
        end
        close(fout)
    end

    if !unpaired
        unpairedlogprobs = computeunpairedlikelihoods(dataset, params)
        pairedlogprobs, ret = coevolutionall(dataset,params,true,false,true,maxbasepairdistance,usecuda)
        inside = computeinsideKH99(unpairedlogprobs, pairedlogprobs, 1.0,false,usecuda)
        outside = computeoutsideKH99(inside,unpairedlogprobs, pairedlogprobs, usecuda)
        unpairedposteriorprobs,pairedposteriorprobs = computebasepairprobs(inside, outside, unpairedlogprobs, pairedlogprobs, KH99())
        fout = open(string(maxfile, ".posteriorunpaired"),"w")
        println(fout,unpairedposteriorprobs)
        close(fout)
        fout = open(string(maxfile, ".posteriorpaired"),"w")
        println(fout,printmatrix(pairedposteriorprobs))
        close(fout)

        ematrix = nothing
        smatrix = nothing
        consensus = getPosteriorDecodingConsensusStructure(pairedposteriorprobs, unpairedposteriorprobs, usecuda)
        fout = open(string(maxfile, ".consensus.dbn"),"w")
        println(fout, getdotbracketstring(consensus))
        close(fout)
        writectfile(consensus, repeat("N", length(consensus)), string(maxfile, ".consensus.ct"))

        pairedlogprobs, ret = coevolutionall(dataset,params,true,true,true,maxbasepairdistance,usecuda)

        museparams = getmusespecificparamsarray(params)
        posteriorcoevolving = zeros(Float64, dataset.numcols, dataset.numcols)
        posteriormeanlambda = zeros(Float64, dataset.numcols, dataset.numcols)
        bayesfactorcoevolving = zeros(Float64, dataset.numcols, dataset.numcols)
        for i=1:dataset.numcols
            posteriorcoevolving[i,i] = 0.0
            for j=i+1:dataset.numcols
                posteriormeanlambda[i,j] = 0.0
                for k=1:length(museparams)
                    posteriormeanlambda[i,j] += museparams[k].lambdarate*exp(ret[k][i,j]-pairedlogprobs[i,j])
                    posteriormeanlambda[j,i] = posteriormeanlambda[i,j]
                    #println(k,"\t",ret[k][i,j],"\t",pairedlogprobs[i,j], "\t", exp(ret[k][i,j]-pairedlogprobs[i,j]))
                end
                postprob = exp(ret[1][i,j]-pairedlogprobs[i,j])
                bf = (postprob/(1.0-postprob))/(params.lambdazeroweight/(1.0-params.lambdazeroweight))
                bayesfactorcoevolving[i,j] = 1.0/bf
                bayesfactorcoevolving[j,i] = 1.0/bf
                posteriorcoevolving[i,j] = 1.0 - exp(ret[1][i,j]-pairedlogprobs[i,j])
                posteriorcoevolving[j,i] = posteriorcoevolving[i,j]
            end
        end
        fout = open(string(maxfile, ".consensus.bp"),"w")
        for i=1:length(consensus)
            bp = "-\t-\t-\t-"
            if consensus[i] > 0
                #println(pairedposteriorprobs[i,consensus[i]])
                #println(posteriorcoevolving[i,consensus[i]])
                #println(bayesfactorcoevolving[i,consensus[i]])
                #println(posteriormeanlambda[i,consensus[i]])
                bp = string(@sprintf("%.4f", pairedposteriorprobs[i,consensus[i]]), "\t", @sprintf("%.4f", posteriorcoevolving[i,consensus[i]]), "\t", @sprintf("%.4e", bayesfactorcoevolving[i,consensus[i]]), "\t", @sprintf("%.4f", posteriormeanlambda[i,consensus[i]]))
            end
            println(fout, i,"\t", consensus[i], "\t", @sprintf("%.4f", unpairedposteriorprobs[i]), "\t", bp, "\t", @sprintf("%.4f", maximum(pairedposteriorprobs[i,:])))
        end

        lambdameans = zeros(Float64, length(consensus))
        for i=1:length(consensus)
            if consensus[i] != 0
                lambdameans[i] = pairedposteriorprobs[i,consensus[i]]*posteriormeanlambda[i,consensus[i]]
            end
        end
        #println(lambdameans)
        rankbycoevolution(outputprefix, alignmentfile, maxfile, consensus, Int[i for i=1:length(consensus)],dataset,lambdameans)

        close(fout)
        cutoff = 0.001
        fout = open(string(maxfile,"_", cutoff, ".csv"),"w")
        println(fout, "\"i\",\"j\",\"paired(i)\",\"paired(j)\",\"paired(i,j)\",\"p(lambda>0)\",\"meanlambda\",\"bayesfactor(lambda>0)\"")
        for i=1:dataset.numcols
            for j=i+1:dataset.numcols
                if pairedposteriorprobs[i,j] >= cutoff
                    println(fout,"\"",i,"\",\"",j,"\",\"",1.0-unpairedposteriorprobs[i],"\",\"",1.0-unpairedposteriorprobs[j],"\",\"",pairedposteriorprobs[i,j],"\",\"",posteriorcoevolving[i,j],"\",\"",posteriormeanlambda[i,j],"\",\"",bayesfactorcoevolving[i,j],"\"")
                end
            end
        end
        close(fout)


        fout = open(string(maxfile, ".posteriorcoevolving"),"w")
        println(fout,printmatrix(posteriorcoevolving))
        close(fout)
        fout = open(string(maxfile, ".posteriormeanlambda"),"w")
        println(fout,printmatrix(posteriormeanlambda))
        close(fout)
        fout = open(string(maxfile, ".bayesfactorcoevolving"),"w")
        println(fout,printmatrix(bayesfactorcoevolving))
        close(fout)
    end
end

function processmax(outputprefix, alignmentfile, maxfile::AbstractString, dataset::Dataset, params::ModelParameters, paired::Array{Int,1}, mapping, usecuda::Bool)
    museparams = getmusespecificparamsarray(params)
    unpaired,pairedloglikelihoods,sampledstates,museconditionals = computeuncachedlikelihood(dataset, params, museparams, zeros(Int,1), paired, 1.0, false)
    lambdameans = zeros(Float64, length(paired))
    postprobs = zeros(Float64, length(paired))
    for i=1:length(paired)
        if paired[i] > i
            totalll = -Inf
            for musespecificparam in museparams
                lambdacat = musespecificparam.lambdacat
                totalll = CommonUtils.logsumexp(totalll, museconditionals[i,lambdacat])
                #
            end
            lambdamean = 0.0
            for musespecificparam in museparams
                lambdacat = musespecificparam.lambdacat
                if lambdacat == 1
                    postprobs[i] = 1.0-exp(museconditionals[i,1]-totalll)
                end
                lambdamean += exp.(museconditionals[i,lambdacat]-totalll)*musespecificparam.lambdarate
            end
            lambdameans[i] = lambdamean
            lambdameans[paired[i]] = lambdamean
        end
    end
    #println("Lambdas: ",lambdameans)
    fout = open(string(maxfile, ".mapped.dbn"),"w")
    println(fout, getdotbracketstring(paired))
    close(fout)
    rankbycoevolution(outputprefix, alignmentfile, maxfile, paired, mapping,dataset,lambdameans)
    return lambdameans,postprobs
end

function computemaxstructure(dataset::Dataset, params::ModelParameters, maxbasepairdistance::Int=500, usecuda::Bool=true, deletegaps::Bool=false)
    unpairedlogprobs = computeunpairedlikelihoods(dataset, params)
    pairedlogprobs, ret = coevolutionall(dataset,params,true,true,true,maxbasepairdistance,usecuda)

    if deletegaps
        mapping = zeros(Int,dataset.numcols)
        revmapping = zeros(Int, dataset.numcols)
        cutoff = 0.5
        index = 1
        for i=1:dataset.numcols
            if dataset.gapfrequency[i] < cutoff
                mapping[i] = index
                revmapping[index] = i
                index += 1
            end
        end
        newlen = index - 1

        unpairedlogprobs_trunc = ones(Float64, newlen)*-Inf
        pairedlogprobs_trunc = ones(Float64, newlen, newlen)*-Inf
        for i=1:dataset.numcols
            if mapping[i] > 0
                unpairedlogprobs_trunc[mapping[i]] = unpairedlogprobs[i]
                for j=1:dataset.numcols
                    if mapping[j] > 0
                        pairedlogprobs_trunc[mapping[i],mapping[j]] = pairedlogprobs[i,j]
                    end
                end
            end
        end
        inside = computeinsideKH99(unpairedlogprobs_trunc, pairedlogprobs_trunc, 1.0,false,usecuda)
        outside = computeoutsideKH99(inside,unpairedlogprobs_trunc, pairedlogprobs_trunc, usecuda)
        unpairedposteriorprobs_trunc,pairedposteriorprobs_trunc = computebasepairprobs(inside, outside, unpairedlogprobs_trunc, pairedlogprobs_trunc, KH99())
        paired_trunc = getPosteriorDecodingConsensusStructure(pairedposteriorprobs_trunc, unpairedposteriorprobs_trunc, usecuda)

        paired = zeros(Int, dataset.numcols)
        for i=1:dataset.numcols
            if mapping[i] > 0
                if paired_trunc[mapping[i]] > 0
                    paired[i] = revmapping[paired_trunc[mapping[i]]]
                end
            end
        end

        return paired
    else
        maskgapped!(pairedlogprobs,dataset.gapfrequency,0.5,-Inf)
        inside = computeinsideKH99(unpairedlogprobs, pairedlogprobs, 1.0,false,usecuda)
        outside = computeoutsideKH99(inside,unpairedlogprobs, pairedlogprobs, usecuda)
        unpairedposteriorprobs,pairedposteriorprobs = computebasepairprobs(inside, outside, unpairedlogprobs, pairedlogprobs, KH99())
        return getPosteriorDecodingConsensusStructure(pairedposteriorprobs, unpairedposteriorprobs, usecuda)
    end
end

function main()
    parsed_args = parse_commandline()

    seed1 = parsed_args["seed"]
    rng = MersenneTwister(seed1)
    seed2 = rand(rng,1:typemax(Int64))
    Random.seed!(seed2)

    usecuda = !parsed_args["cpuonly"]

    alignmentfilein = parsed_args["alignment"]
    defaultname = split(basename(parsed_args["alignment"]), ".")[1]
    outputprefix = abspath(joinpath("results", defaultname, defaultname))
    if parsed_args["outputprefix"] != nothing
        outputprefix = abspath(string(parsed_args["outputprefix"]))
    end
    println("Output will be written to: \"", outputprefix, "\"")
    outputprefixold = string(outputprefix)
    if parsed_args["shuffle"]
        outputprefix = string(outputprefix, ".shuffle",seed1)
    end
    outputdir = dirname(outputprefix)
    mkpath(outputdir)
    newlog(string(outputprefix, ".log"))
    if parsed_args["shuffle"]
        alignmentfilein = shufflealignment(rng, alignmentfilein, string(outputprefix, ".fas"))
    end
    alignmentfile = cleandataset(alignmentfilein, string(outputprefix,".fas.norm"))
    mcmclogfile = string(outputprefix,".log")
    if parsed_args["tree"] == nothing
        treefile = "$outputprefix.nwk"
        newickstring, treepath = Binaries.fasttreegtr(alignmentfile)
        fout = open(treefile,"w")
        println(fout, newickstring)
        close(fout)
    else
        treefile = parsed_args["tree"]
    end
    grammar = KH99()

    dataset = Dataset(getalignmentfromfastaandnewick(alignmentfile,treefile))


    mode = MODE_IO_SAMPLE
    #mode = MODE_VIENNA_SAMPLE
    if parsed_args["structure"] != nothing
        sequence, pairedsites, mapping, revmapping = mapstructure(dataset,alignmentfile,parsed_args["structure"])
        mode = MODE_FIXED_STRUCTURE
        println("MODE_FIXED_STRUCTURE")
    end

    M = parsed_args["M"]

    lambdaCats = parsed_args["numlambdacats"]
    lambdarates = ones(Float64,lambdaCats)
    lambdaweights = ones(Float64,length(lambdarates)) / length(lambdarates)

    samplebranchlengths = false
    currentparams = ModelParameters(dataset.obsfreqs, 8.0, 4.0, 2.0, 1.0, 5.0, 1.0, 1.0, 5.0, 0.25, getnodelist(dataset.root), 0.5, lambdarates, lambdaweights)
    currentparams.lambdaCats = lambdaCats - 1
    #currentparams.lambdaweightsGC, currentparams.lambdaratesGC = discretizegamma2(currentparams.lambdazeroweight, currentparams.lambdaGammaShapeGC, currentparams.lambdaGammaScaleGC, currentparams.lambdaCats)
    #currentparams.lambdaweightsAT, currentparams.lambdaratesAT = discretizegamma2(currentparams.lambdazeroweight, currentparams.lambdaGammaShapeAT, currentparams.lambdaGammaScaleAT, currentparams.lambdaCats)
    #currentparams.lambdaweightsGT, currentparams.lambdaratesGT = discretizegamma2(currentparams.lambdazeroweight, currentparams.lambdaGammaShapeGT, currentparams.lambdaGammaScaleGT, currentparams.lambdaCats)
    currentparams.lambdaweightsGC, currentparams.lambdaratesGC, currentparams.lambdaweightsAT, currentparams.lambdaratesAT, currentparams.lambdaweightsGT, currentparams.lambdaratesGT = discretizegamma3(currentparams.lambdazeroweight, currentparams.lambdaGammaShapeGC, currentparams.lambdaGammaShapeAT, currentparams.lambdaGammaShapeGT, currentparams.lambdaGammaScaleGC, currentparams.lambdaCats)
    siteCats = parsed_args["numsitecats"]
    currentparams.siteCats = siteCats
    currentparams.siteWeights = ones(Float64,currentparams.siteCats)/currentparams.siteCats
    currentparams.siteRates = discretizegamma(currentparams.siteGammaShape, currentparams.siteGammaScale, currentparams.siteCats)
    currentparams.states = Int[rand(rng,1:currentparams.siteCats) for i=1:dataset.numcols]
    currentparams.pairedstates = Int[rand(rng,1:lambdaCats) for i=1:dataset.numcols]


    initialparams = Float64[2.0,2.0,2.0,1.7487740904105369,4.464074402974858,1.6941505179847807,0.4833108030758708,5.839004646491171,0.7168678100059017,1.0,0.6118067582467858,0.23307618715645315,0.2631203272837885,0.2430685428508905,0.5,1.0,1.0,1.0,1.0,1.0]
    initialparams[10] = 1.0
    initialparams[16] = 1.0
    initialparams[17] = 1.0
    initialparams[18] = 1.0
    initialparams[19] = 1.0
    initialparams[20] = 1.0


    maxbasepairdistance = parsed_args["maxbasepairdistance"]

    integratesiterates = true
    integratestructure = false

    maxfile = string(outputprefix, ".max")
    maxfileold = string(outputprefixold,".max")
    maxfileunpaired = string(outputprefix, ".max.unpaired")
    if isfile(maxfile)
        jsondict = JSON.parsefile(maxfile)
        initialparams = convert(Array{Float64,1}, jsondict["maxparams"])
    elseif isfile(maxfileold)
        jsondict = JSON.parsefile(maxfileold)
        initialparams = convert(Array{Float64,1}, jsondict["maxparams"])
    elseif isfile(maxfileunpaired)
        jsondict = JSON.parsefile(maxfileunpaired)
        initialparams = convert(Array{Float64,1}, jsondict["maxparams"])
        #initialparams[10] = 5.0/10.0
        initialparams[10] = 5.0
        initialparams[16] = 0.25
        #initialparams[17] = 3.0/10.0
        initialparams[17] = 3.0
        initialparams[18] = 10.0
        #initialparams[19] = 1.0/10.0
        initialparams[19] = 2.0
        initialparams[20] = 10.0
    end
    currentparams = getparams(initialparams,dataset,siteCats,lambdaCats,0)

    if parsed_args["fixgcau"] && parsed_args["fixgu"]
        maxfile = string(outputprefix, ".fixgcaugu.max")
        if isfile(maxfile)
            jsondict = JSON.parsefile(maxfile)
            initialparams = convert(Array{Float64,1}, jsondict["maxparams"])
        end
        currentparams = getparams(initialparams,dataset,siteCats,lambdaCats,0)
        #currentparams.lambdazeroweight = max(currentparams.lambdazeroweight, 0.05)
    elseif parsed_args["fixgcau"]
        maxfile = string(outputprefix, ".fixgcau.max")
        if isfile(maxfile)
            jsondict = JSON.parsefile(maxfile)
            initialparams = convert(Array{Float64,1}, jsondict["maxparams"])
        end
        currentparams = getparams(initialparams,dataset,siteCats,lambdaCats,0)
        #currentparams.lambdazeroweight = max(currentparams.lambdazeroweight, 0.05)
    elseif parsed_args["fixgu"]
        maxfile = string(outputprefix, ".fixgu.max")
        if isfile(maxfile)
            jsondict = JSON.parsefile(maxfile)
            initialparams = convert(Array{Float64,1}, jsondict["maxparams"])
        end
        currentparams = getparams(initialparams,dataset,siteCats,lambdaCats,0)
        #currentparams.lambdazeroweight = max(currentparams.lambdazeroweight, 0.05)
    end
    if parsed_args["shuffle"]
        currentparams.lambdazeroweight = 0.50
    end
    if parsed_args["unpaired"]
        maxfile = string(outputprefix, ".max.unpaired")
        if isfile(maxfile)
            jsondict = JSON.parsefile(maxfile)
            initialparams = convert(Array{Float64,1}, jsondict["maxparams"])
        end
        currentparams = getparams(initialparams,dataset,siteCats,lambdaCats,0)
    end

    if parsed_args["processmax"]
        if parsed_args["structure"] != nothing
            processmax(outputprefix, alignmentfile, maxfile, dataset, currentparams, pairedsites, mapping, usecuda)
        else
            processmax(outputprefix, alignmentfile, maxfile, dataset, currentparams, maxbasepairdistance, usecuda, parsed_args["unpaired"])
        end
        exit()
    end

    if parsed_args["maxstructure"]
        println("Computing maximum likelihood structure")
        maxstructure_trunc = computemaxstructure(dataset, currentparams, maxbasepairdistance, usecuda,true)
        writectfile(maxstructure_trunc, replace(dataset.sequences[1], "-" => "N"), string(outputprefix, ".maxstructuretrunc"))
        maxstructure = computemaxstructure(dataset, currentparams, maxbasepairdistance, usecuda)
        writectfile(maxstructure, replace(dataset.sequences[1], "-" => "N"), string(outputprefix, ".maxstructure"))
        exit()
    end

    if parsed_args["calcentropy"] || parsed_args["calcpriorentropy"]
        initialparams = convert(Array{Float64,1}, jsondict["maxparams"])
        currentparams = getparams(initialparams,dataset,siteCats,lambdaCats,0)
        println("PARAMS",initialparams)
        h, hmax = computeinformationentropy(dataset, currentparams, maxbasepairdistance, usecuda)
        #println("H=", h)
        H, Hstdev, Hstderr, Hmax, perc = estimateinformationentropy(rng, dataset, currentparams, maxbasepairdistance, usecuda, parsed_args["calcpriorentropy"])
        jsondict2 = Dict()
        jsondict2["params"] = initialparams
        jsondict2["H"] = H
        jsondict2["Hstdev"] = Hstdev
        jsondict2["Hstderr"] = Hstderr
        jsondict2["Hmax"] = Hmax
        jsondict2["percentage"] = perc
        jsondict2["length"] = dataset.numcols
        entropyfile =  string(outputprefix, ".entropy")
        if parsed_args["fixgu"]
            entropyfile = string(outputprefix, ".fixgu.entropy")
        end
        if parsed_args["calcpriorentropy"]
            entropyfile =  string(outputprefix, ".entropyprior")
        end
        out = open(entropyfile,"w")
        ret = replace(JSON.json(jsondict2),",\"" => ",\n\"")
        ret = replace(ret, "],[" => "],\n[")
        ret = replace(ret, "{" => "{\n")
        ret = replace(ret, "}" => "\n}")
        write(out,ret)
        close(out)

        println("Entropy = ", H)
        #println("Entropy est ", hest)
        println("Max. entropy = ", Hmax)
        println("Norm. entropy = ", perc)
        exit()
    end

    optimize = !parsed_args["mcmc"]
    if optimize
        fixGU = parsed_args["fixgu"]
        fixGCAU = parsed_args["fixgcau"]
        integratestructure = parsed_args["structure"] == nothing
        unpairedmodel = parsed_args["unpaired"]
        if integratestructure && unpairedmodel
            integratestructure = false
        end

        if integratestructure
            maxoptiter = parsed_args["maxmcemiter"]
            samplesperiter = parsed_args["samplesperiter"]
            if samplesperiter > 0
                println("MCEM")
                currentparams = mcem(dataset, siteCats, lambdaCats, fixGU, fixGCAU, unpairedmodel,maxoptiter,samplesperiter,maxbasepairdistance,currentparams, maxfile, usecuda)
            else
                currentparams = optimizemodel(dataset, (parsed_args["structure"] == nothing ? zeros(Int,dataset.numcols) : pairedsites), siteCats, lambdaCats, fixGU,fixGCAU, true, unpairedmodel,2000,currentparams, maxfile, usecuda)
            end
        else
            maxoptiter = 2000
            currentparams = optimizemodel(dataset,  (parsed_args["structure"] == nothing ? zeros(Int,dataset.numcols) : pairedsites), siteCats,lambdaCats,fixGU,fixGCAU,integratestructure,unpairedmodel,maxoptiter,currentparams, maxfile, usecuda)
        end
        exit()
    end

    if parsed_args["mcmc"]
        parameterisation = 0
        if parameterisation == 1
            gammameanGC = currentparams.lambdaGammaShapeGC*currentparams.lambdaGammaScaleGC
            #currentparams.lambdaGammaScaleGC = gammameanGC/currentparams.lambdaGammaScaleGC
            currentparams.lambdaGammaShapeGC = gammameanGC

            gammameanAT = currentparams.lambdaGammaShapeAT*currentparams.lambdaGammaScaleGC
            #currentparams.lambdaGammaScaleAT = gammameanAT/currentparams.lambdaGammaScaleAT
            currentparams.lambdaGammaShapeAT = gammameanAT

            gammameanGT = currentparams.lambdaGammaShapeGT*currentparams.lambdaGammaScaleGC
            #currentparams.lambdaGammaScaleGT = gammameanGT/currentparams.lambdaGammaScaleGT
            currentparams.lambdaGammaShapeGT = gammameanGT
        end
        currentparams.lambdaweightsGC, currentparams.lambdaratesGC, currentparams.lambdaweightsAT, currentparams.lambdaratesAT, currentparams.lambdaweightsGT, currentparams.lambdaratesGT = discretizegamma3(currentparams.lambdazeroweight, currentparams.lambdaGammaShapeGC, currentparams.lambdaGammaShapeAT, currentparams.lambdaGammaShapeGT, currentparams.lambdaGammaScaleGC, currentparams.lambdaCats, parameterisation)
        proposedparams = deepcopy(currentparams)


        inside = zeros(Float64,1,1,1)
        if mode == MODE_IO_SAMPLE
            fout = open(string(outputprefix, ".calculations"), "w")
            computations = countcomputations(dataset, maxbasepairdistance)
            write(fout, string(computations, "\n"))
            write(fout, string(dataset.numseqs,"\t", dataset.numcols,"\n"))
            write(fout, string(@sprintf("%.3f", computations[6]), "\n"))
            write(fout, string(@sprintf("%.2f", 1.0/computations[6]), "\n"))
            close(fout)

            unpairedlogprobs = computeunpairedlikelihoods(dataset, currentparams)
            museparams = getmusespecificparamsarray(currentparams)
            #tic()
            pairedlogprobs, ret = coevolutionall(dataset,currentparams,true,false,true,maxbasepairdistance,usecuda)
            maskgapped!(pairedlogprobs,dataset.gapfrequency,0.5,-Inf)
            inside = computeinsideKH99(unpairedlogprobs, pairedlogprobs, 1.0,false,usecuda)
            savemaximum(inside[1,1,dataset.numcols], getparamsvector(currentparams), maxfile)
            #elapsed = toc();
            #println("MCMC initialised: ", elapsed)
        end

        thermodynamicsamples = Dict{Int, Array{Array{Int,1}}}()

        #Bs = [1.0]
        Bs = [parsed_args["bfactor"]^(z-1.0) for z=1:parsed_args["numchains"]]

        if samplebranchlengths
            currentparams.q6 = 1.0
        end
        chains = Chain[]
        id = 1
        for B in Bs
            if mode == MODE_IO_SAMPLE
                chain = Chain(id, B, MersenneTwister(rand(rng,1:typemax(Int64))), 0.0, 0.0, currentparams, zeros(Int,dataset.numcols), copy(inside), pairedlogprobs, unpairedlogprobs, copy(inside), copy(pairedlogprobs), copy(unpairedlogprobs), deepcopy(currentparams))
                chain.pairedlogprior = samplestructure(chain.rng, chain.inside, chain.pairedlogprobs, chain.unpairedlogprobs, 1, dataset.numcols, chain.paired, grammar, chain.B)
            elseif mode == MODE_VIENNA_SAMPLE
                chain = Chain(id, B, MersenneTwister(rand(rng,1:typemax(Int64))), 0.0, 0.0, currentparams, zeros(Int,dataset.numcols), zeros(Float64,1,1,1), zeros(Float64,1,1), zeros(Float64,1))
                chain.paired = samplethermodynamic(thermodynamicsamples, rng,dataset.sequences)
            else
                chain = Chain(id, B, MersenneTwister(rand(rng,1:typemax(Int64))), 0.0, 0.0, currentparams, zeros(Int,dataset.numcols), zeros(Float64,1,1,1), zeros(Float64,1,1), zeros(Float64,1), zeros(Float64,1,1,1), zeros(Float64,1,1), zeros(Float64,1), deepcopy(currentparams))
                chain.paired = copy(pairedsites)
            end
            chain.currentll = computetotallikelihood(chain.rng, dataset, chain.currentparams, chain.paired, samplebranchlengths,integratesiterates,integratestructure, M)
            chain.proposedll = chain.currentll
            push!(chains, chain)
            id += 1
        end


        burnins = Int[250, 500, 1000, 1500, 2000,2500, 3000, 4000,5000,6000, 7500, 9000, 10000]
        if samplebranchlengths
            burnins = Int[max(1500,dataset.numseqs*100),max(4500,dataset.numseqs*300)]
        end
        if length(burnins) > 0
            burnindata = zeros(Float64,burnins[end],10)
        end



        mcmcoptions = MCMCoptions(mode,M,samplebranchlengths,integratesiterates,integratestructure,maxbasepairdistance,usecuda)

        numChains =  length(Bs)
        swapacceptance = ones(Float64, numChains, numChains)*5e-11
        swaptotal = ones(Float64, numChains, numChains)*1e-10
        maxll = -Inf
        tuningvectors = Array{Float64,1}[]
        branchtuningvectors = Array{Float64,1}[]
        covmat = nothing
        for i=1:1000000
            for chain in chains
                covmat = runchain(10,chain, dataset, grammar, outputprefix, string(outputprefix,".B",chain.B,".M",M), mcmcoptions, burnins, burnindata, thermodynamicsamples, tuningvectors, branchtuningvectors, covmat)
                if chain.currentll > maxll
                    maxll = chain.currentll
                end
            end
            for k=1:length(chains)
                sel = [i for i=1:numChains]
                shuffle!(rng, sel)
                if length(sel) > 1
                    a = sel[1]
                    b = sel[2]
                    S = (chains[b].B-chains[a].B)*(chains[a].currentll + chains[a].pairedlogprior - chains[b].currentll - chains[b].pairedlogprior)
                    if exp(S) > rand(rng)
                        chains[a].B, chains[b].B = chains[b].B, chains[a].B
                        chains[a].id, chains[b].id = chains[b].id, chains[a].id
                        chains[a].logger, chains[b].logger = chains[b].logger, chains[a].logger
                        chains[a].timings, chains[b].timings = chains[b].timings, chains[a].timings
                        swapacceptance[chains[a].id,chains[b].id] += 1.0
                        swapacceptance[chains[b].id,chains[a].id] += 1.0
                    end
                    swaptotal[chains[a].id,chains[b].id] += 1.0
                    swaptotal[chains[b].id,chains[a].id] += 1.0
                    println(swapacceptance./swaptotal)
                end
            end

        end
    end
end

main()