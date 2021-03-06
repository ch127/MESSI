include("InsideOutsideAlgorithm.jl")
try
  using CUDAdrv, CUDAnative, CuArrays
catch
  println("Unable to use CUDA GPU acceleration.")
end

function getdotbracketstring(pairedsites::Array{Int,1})
  s = ""
  for i=1:length(pairedsites)
    if pairedsites[i] > i
      s = string(s,"(")
    elseif pairedsites[i] == 0
      s = string(s,".")
    else
      s = string(s,")")
    end
  end

  return s
end

function computeinsideKH99(unpairedlogprobs::Array{Float64,1}, pairedlogprobs::Array{Float64,2}, B::Float64=1.0, zonly::Bool=true, usecudain::Bool=true)
  usecuda = usecudain
  if usecuda
    try
      if length(unpairedlogprobs) > 3000
        #println("INSIDE START")
        #CuArrays.pool_status()
      end
      ret = computeinsidecuda(unpairedlogprobs, pairedlogprobs, B, zonly)
      if length(unpairedlogprobs) > 3000
        #println("INSIDE END")
        #CuArrays.pool_status()
      end
      return ret
    catch e
        println(e)
        println(stacktrace(catch_backtrace()))
        println("CUDA GPU not available.")
        usecuda = false
    end
  end

  if !usecuda
    inside = computeinsideparallel(unpairedlogprobs, pairedlogprobs, KH99(), B)
    if zonly
      return inside[1,1,length(unpairedlogprobs)]
    else
      return inside
    end
  end
end

function computeoutsideKH99(inside::Array{Float64,3}, unpairedlogprobs::Array{Float64,1}, pairedlogprobs::Array{Float64,2}, usecuda::Bool=true)
  if usecuda
    return computeoutsidecuda(inside,unpairedlogprobs, pairedlogprobs)
  else
    return computeoutside(inside,unpairedlogprobs, pairedlogprobs, KH99())
  end
end

function computeinsidecuda(unpairedlogprobs::Array{Float64,1}, pairedlogprobs::Array{Float64,2}, B::Float64=1.0, zonly::Bool=true)
  len = length(unpairedlogprobs)
  unpairedlogprobssafe = ones(Float32, len)*Float32(-1e20)
  pairedlogprobssafe = ones(Float32, len, len)*Float32(-1e20)
  for i=1:len
    if unpairedlogprobs[i] < -1e20
      unpairedlogprobssafe[i] = Float32(-1e20)
    else
      unpairedlogprobssafe[i] = Float32(unpairedlogprobs[i])
    end
    for j=i+1:len
      if pairedlogprobs[i,j] < -1e20
        pairedlogprobssafe[i,j] = Float32(-1e20)
        pairedlogprobssafe[j,i] = pairedlogprobs[j,i]
      else
        pairedlogprobssafe[i,j] = Float32(pairedlogprobs[i,j])
        pairedlogprobssafe[j,i] = pairedlogprobs[j,i]
      end
    end
  end

  return computeinsidecuda(unpairedlogprobssafe, pairedlogprobssafe, KH99(), B, zonly)
end

function computeinsidecuda(unpairedlogprobs::Array{Float32,1}, pairedlogprobs::Array{Float32,2}, grammar::KH99, B::Float64=1.0, zonly::Bool=true)
  type1rules = grammar.type1rules
  type2rules = grammar.type2rules
  type3rules = grammar.type3rules
  numnonterminals = 3
  len = length(unpairedlogprobs)

  

  dev = CuDevice(0)
  ctx = CuContext(dev)
  if len > 3000
    println("INSIDE MIDDLE")
    CuArrays.pool_status()
  end

  md = CuModuleFile(joinpath(@__DIR__,"cuda","inside.ptx"))

  d_Z = CuArray(zeros(Float32,1))
  #cudainitialiseinside = CuFunction(md, "_Z16initialiseinsidePfPKfi")
  cudainitialiseinside2 = CuFunction(md, "_Z16initialiseinsidePfS_S_PKfi")
  #cudainside = CuFunction(md, "_Z15insidealgorithmPfPKfS1_iif")
  cudainside2 = CuFunction(md, "_Z15insidealgorithmPfS_S_PKfS1_iif")
  cudainsidez = CuFunction(md, "_Z7insidezPKfPfi")
  blocksize = 256

  d_unpairedlogprobs= CuArray(unpairedlogprobs)
  d_pairedlogprobs = CuArray(Array(transpose(pairedlogprobs)))

  if zonly
    d_insideS = CuArray(zeros(Float32, len*len))
    d_insideL = CuArray(zeros(Float32, len*len))
    d_insideF = CuArray(zeros(Float32, len*len))
    cudacall(cudainitialiseinside2, (CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, Cint), d_insideS, d_insideL, d_insideF, d_unpairedlogprobs, len, blocks=div(len+blocksize-1, blocksize), threads=blocksize)
    for a=1:len-1
      cudacall(cudainside2, (CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, Cint, Cint, Cfloat), d_insideS, d_insideL, d_insideF, d_pairedlogprobs, d_unpairedlogprobs, a, len, Float32(B), blocks=div(len+blocksize-1, blocksize), threads=blocksize)
    end
    cudacall(cudainsidez, (CuPtr{Cfloat}, CuPtr{Cfloat}, Cint), d_insideS, d_Z, len, blocks=div(len+blocksize-1, blocksize), threads=blocksize)
    Zvec = Array(d_Z)
    finalize(d_unpairedlogprobs)
    finalize(d_pairedlogprobs)
    finalize(d_insideS)
    finalize(d_insideL)
    finalize(d_insideF)
    finalize(d_Z)
    GC.gc()
    destroy!(ctx)
    synchronize(ctx)
    return Float64(Zvec[1])
  else
    d_insideS = CuArray(zeros(Float32, len*len))
    d_insideL = CuArray(zeros(Float32, len*len))
    d_insideF = CuArray(zeros(Float32, len*len))
    cudacall(cudainitialiseinside2, (CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, Cint), d_insideS, d_insideL, d_insideF, d_unpairedlogprobs, len, blocks=div(len+blocksize-1, blocksize), threads=blocksize)
    for a=1:len-1
      cudacall(cudainside2, (CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, Cint, Cint, Cfloat), d_insideS, d_insideL, d_insideF, d_pairedlogprobs, d_unpairedlogprobs, a, len, Float32(B), blocks=div(len+blocksize-1, blocksize), threads=blocksize)
    end

    inside = zeros(Float64, numnonterminals, len, len)
    insidevec = Array(d_insideS)
    index = 1
    for i=1:len
      for j=1:len
        inside[1,i,j] = Float64(insidevec[index])
        index += 1
      end
    end
    insidevec = Array(d_insideF)
    index = 1
    for i=1:len
      for j=1:len
        inside[2,i,j] = Float64(insidevec[index])
        index += 1
      end
    end
    insidevec = Array(d_insideL)
    index = 1
    for i=1:len
      for j=1:len
        inside[3,i,j] = Float64(insidevec[index])
        index += 1
      end
    end
    finalize(d_unpairedlogprobs)
    finalize(d_pairedlogprobs)
    finalize(d_insideS)
    finalize(d_insideL)
    finalize(d_insideF)
    finalize(d_Z)
    GC.gc()
    destroy!(ctx)
    synchronize(ctx)
    return inside
  end
end

function computeposteriordecodingcuda(singleprobsin::Array{Float64,1}, pairprobsin::Array{Float64,2}, alpha::Float64=2.0)
  singleprobs = convert(Array{Float32,1}, singleprobsin)
  pairprobs = convert(Array{Float32,2}, pairprobsin)
  len = length(singleprobs)
  dev = CuDevice(0)
  ctx = CuContext(dev)
  md = CuModuleFile(joinpath(@__DIR__,"cuda","inside.ptx"))

  cudaposteriordecoding = CuFunction(md, "_Z17posteriordecodingPfPiPKfS2_iif")
  blocksize = 256

  d_singleprobs = CuArray(singleprobs)
  d_pairprobs = CuArray(pairprobs)
  ematrix = zeros(Float32, len, len)
  for i=1:len
    #ematrix[i,i] = singleprobs[i]
  end
  d_ematrix=  CuArray(ematrix)
  d_smatrix= CuArray(zeros(Int32, len, len))
  for diag=2:len
    cudacall(cudaposteriordecoding, (CuPtr{Cfloat}, CuPtr{Cint}, CuPtr{Cfloat}, CuPtr{Cfloat}, Cint, Cint, Cfloat), d_ematrix, d_smatrix, d_pairprobs, d_singleprobs, convert(Int32, len), convert(Int32, diag-1), convert(Float32, alpha), blocks=div(len+blocksize-1, blocksize), threads=blocksize)
  end
  ematrix = Array(transpose(reshape(Array(d_ematrix), (len,len))))
  smatrix = Array(transpose(reshape(Array(d_smatrix), (len,len))))
  finalize(d_singleprobs)
  finalize(d_pairprobs)
  finalize(d_ematrix)
  finalize(d_smatrix)
  GC.gc()
  destroy!(ctx)
  synchronize(ctx)
  return convert(Array{Float64, 2}, ematrix), convert(Array{Int, 2}, smatrix)
end

function computeinsidecudadouble(unpairedlogprobs::Array{Float64,1}, pairedlogprobs::Array{Float64,2}, B::Float64=1.0)
  len = length(unpairedlogprobs)
  unpairedlogprobssafe = ones(Float64, len)*Float64(-1e20)
  pairedlogprobssafe = ones(Float64, len, len)*Float64(-1e20)
  for i=1:len
    if unpairedlogprobs[i] < -1e20
      unpairedlogprobssafe[i] = Float64(-1e20)
    else
      unpairedlogprobssafe[i] = Float64(unpairedlogprobs[i])
    end
    for j=i+1:len
      if pairedlogprobs[i,j] < -1e20
        pairedlogprobssafe[i,j] = Float64(-1e20)
        pairedlogprobssafe[j,i] = pairedlogprobs[j,i]
      else
        pairedlogprobssafe[i,j] = Float64(pairedlogprobs[i,j])
        pairedlogprobssafe[j,i] = pairedlogprobs[j,i]
      end
    end
  end

  return computeinsidecudadouble(unpairedlogprobs, pairedlogprobs, KH99(), B)
end

#=
function computeinsidecudadouble(unpairedlogprobs::Array{Float64,1}, pairedlogprobs::Array{Float64,2}, grammar::KH99, B::Float64=1.0)
type1rules = grammar.type1rules
type2rules = grammar.type2rules
type3rules = grammar.type3rules
numnonterminals = 3
len = length(unpairedlogprobs)
inside = ones(Float64, numnonterminals, len, len)*Float64(-1e20)
for type1rule in type1rules
for i=1:len
inside[type1rule.leftindex, i,i] = (unpairedlogprobs[i] + type1rule.logprob)*B
end
end

insidevec = zeros(Float64, 3*len*len)
index = 1
for s=1:3
for i=1:len
for j=1:len
insidevec[index] = inside[s,i,j]
index += 1
end
end
end



devlist = devices(dev->true)
dev = device(devlist[1])
md = CuModuleFile("cuda/insidedouble.ptx")
d_inside = CuArray(insidevec)
d_pairedlogprobs = CuArray(transpose(pairedlogprobs))
d_unpairedlogprobs= CuArray(unpairedlogprobs)
cudainside = CuFunction(md, "_Z15insidealgorithmPdPKdS1_iid")
blocksize = 512

for a=1:len-1
cudacall(cudainside, div(len+blocksize-1, blocksize), blocksize, (Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Int32, Int32, Float64), d_inside, d_pairedlogprobs, d_unpairedlogprobs, a, len, Float64(B))
end
insidevec = to_host(d_inside)
#pairedlogprobs = to_host(d_pairedlogprobs)
#println(insidevec)
#println("Z=",insidevec[len*len+len+len])

index = 1
for s=1:3
for i=1:len
for j=1:len
inside[s,i,j] = insidevec[index]
index += 1
end
end
end

#println(inside)


return inside
end=#

function computeoutsidecuda(inside::Array{Float64,3}, unpairedlogprobs::Array{Float64,1}, pairedlogprobs::Array{Float64,2})
  len = length(unpairedlogprobs)
  unpairedlogprobssafe = ones(Float32, len)*Float32(-1e20)
  pairedlogprobssafe = ones(Float32, len, len)*Float32(-1e20)
  for i=1:len
    if unpairedlogprobs[i] < -1e20
      unpairedlogprobssafe[i] = Float32(-1e20)
    else
      unpairedlogprobssafe[i] = Float32(unpairedlogprobs[i])
    end
    for j=i+1:len
      if pairedlogprobs[i,j] < -1e20
        pairedlogprobssafe[i,j] = Float32(-1e20)
        pairedlogprobssafe[j,i] = pairedlogprobs[j,i]
      else
        pairedlogprobssafe[i,j] = Float32(pairedlogprobs[i,j])
        pairedlogprobssafe[j,i] = pairedlogprobs[j,i]
      end
    end
  end

  return computeoutsidecuda(convert(Array{Float32,3},inside), unpairedlogprobssafe, pairedlogprobssafe, KH99())
end

function computeoutsidecuda(inside::Array{Float32,3}, unpairedlogprobs::Array{Float32,1}, pairedlogprobs::Array{Float32,2}, grammar::KH99, B::Float64=1.0)
  type1rules = grammar.type1rules
  type2rules = grammar.type2rules
  type3rules = grammar.type3rules
  numnonterminals = 3
  len = length(unpairedlogprobs)
  outside = ones(Float32, numnonterminals, len, len)*Float32(-1e20)
  outside[1, 1, len] = 0.0

  outsidevec = zeros(Float32, 3*len*len)
  index = 1
  for s=1:3
    for i=1:len
      for j=1:len
        outsidevec[index] = outside[s,i,j]
        index += 1
      end
    end
  end

  insidevec = zeros(Float32, 3*len*len)
  index = 1
  for s=1:3
    for i=1:len
      for j=1:len
        insidevec[index] = inside[s,i,j]
        index += 1
      end
    end
  end

  dev = CuDevice(0)
  ctx = CuContext(dev)
  md = CuModuleFile(joinpath(@__DIR__,"cuda","inside.ptx"))
  d_outside = CuArray(outsidevec)
  d_inside = CuArray(insidevec)
  d_pairedlogprobs = CuArray(Array(transpose(pairedlogprobs)))
  d_unpairedlogprobs= CuArray(unpairedlogprobs)
  cudaoutside = CuFunction(md, "_Z16outsidealgorithmPfPKfS1_S1_iif")
  blocksize = 1024

  a = len - 2
  while a >= 0
    cudacall(cudaoutside, (CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, CuPtr{Cfloat}, Cint, Cint, Cfloat), d_outside, d_inside, d_pairedlogprobs, d_unpairedlogprobs, a, len, Float32(B), blocks=div(len+blocksize-1, blocksize), threads=blocksize)
    a -= 1
  end

  outsidevec = Array(d_outside)

  index = 1
  for s=1:3
    for i=1:len
      for j=1:len
        outside[s,i,j] = outsidevec[index]
        index += 1
      end
    end
  end

  GC.gc()
  destroy!(ctx)
  synchronize(ctx)

  return convert(Array{Float64,3}, outside)
end
