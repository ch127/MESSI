using CUDAdrv

function countcomputations(dataset::Dataset, maxbasepairdistance::Int=1000000)
    nodelist = getnodelist(dataset.root)
    xindices = [Int32[] for node in nodelist]
    yindices = [Int32[] for node in nodelist]
    indexdict = Dict{Int,Int}[Dict{Int,Int}() for node in nodelist]
    cachedcalculations = 0
    internalnodecachedcalculations = 0

    uncachedcalculations = 0
    internalnodeuncachedcalculations = 0
    for node in nodelist
        for x=1:dataset.numcols
            yend = min(x+maxbasepairdistance,dataset.numcols)
            for y=x+1:yend
                uncachedcalculations += 1
                if !isleafnode(node)
                    internalnodeuncachedcalculations += 1
                end
            end
        end
    end

    for node in nodelist
        xin = xindices[node.nodeindex]
        yin = yindices[node.nodeindex]
        count = 0
        if node.nodeindex == 1
            for x=1:dataset.numcols
                yend = min(x+maxbasepairdistance,dataset.numcols)
                for y=x+1:yend
                    key = node.nodeindex*dataset.numcols*dataset.numcols + (dataset.subcolumnrefs[node.nodeindex,x])*dataset.numcols + dataset.subcolumnrefs[node.nodeindex,y]
                    if !haskey(indexdict[node.nodeindex], key)
                        push!(xin,Int32(x))
                        push!(yin,Int32(y))
                        indexdict[node.nodeindex][key] = count
                        count += 1
                        cachedcalculations += 1
                        if !isleafnode(node)
                            internalnodecachedcalculations += 1
                        end
                    end
                end
            end
        else
            parentindex = get(node.parent).nodeindex
            xpar = xindices[parentindex]
            ypar = yindices[parentindex]
            for z=1:length(xpar)
                x = xpar[z]
                y = ypar[z]
                key = node.nodeindex*dataset.numcols*dataset.numcols + (dataset.subcolumnrefs[node.nodeindex,x])*dataset.numcols + dataset.subcolumnrefs[node.nodeindex,y]
                if !haskey(indexdict[node.nodeindex], key)
                    push!(xin,Int32(x))
                    push!(yin,Int32(y))
                    indexdict[node.nodeindex][key] = count
                    count += 1
                    cachedcalculations += 1
                    if !isleafnode(node)
                        internalnodecachedcalculations += 1
                    end
                end
            end
        end
    end



    return cachedcalculations, uncachedcalculations, internalnodecachedcalculations, internalnodeuncachedcalculations, cachedcalculations/uncachedcalculations, internalnodecachedcalculations/internalnodeuncachedcalculations
end

function getindexdict(dataset::Dataset, maxbasepairdistance::Int=1000000)
    alphabet::Int32 = Int32(16)
    nodelist = getnodelist(dataset.root)
    xindices = [Int32[] for node in nodelist]
    yindices = [Int32[] for node in nodelist]
    indexdict = Dict{Int,Int}[Dict{Int,Int}() for node in nodelist]
    for node in nodelist
        xin = xindices[node.nodeindex]
        yin = yindices[node.nodeindex]
        count = 0
        if node.nodeindex == 1
            for x=1:dataset.numcols
                yend = min(x+maxbasepairdistance,dataset.numcols)
                for y=x+1:yend
                    if  dataset.maxbasepairprobs[x,y] > 0.0
                        key = node.nodeindex*dataset.numcols*dataset.numcols + (dataset.subcolumnrefs[node.nodeindex,x])*dataset.numcols + dataset.subcolumnrefs[node.nodeindex,y]
                        if !haskey(indexdict[node.nodeindex], key)
                            push!(xin,Int32(x))
                            push!(yin,Int32(y))
                            indexdict[node.nodeindex][key] = count
                            count += 1
                        end
                    end
                end
            end
        else
            parentindex = get(node.parent).nodeindex
            xpar = xindices[parentindex]
            ypar = yindices[parentindex]
            for z=1:length(xpar)
                x = xpar[z]
                y = ypar[z]
                key = node.nodeindex*dataset.numcols*dataset.numcols + (dataset.subcolumnrefs[node.nodeindex,x])*dataset.numcols + dataset.subcolumnrefs[node.nodeindex,y]
                if !haskey(indexdict[node.nodeindex], key)
                    push!(xin,Int32(x))
                    push!(yin,Int32(y))
                    indexdict[node.nodeindex][key] = count
                    count += 1
                end
            end
        end
    end

    leftrightindices = Dict{Int,Tuple{Array{Int32,1},Array{Int32,1}}}()
    for node in nodelist
        if !isleafnode(node)
            leftchildindex = node.children[1].nodeindex
            rightchildindex = node.children[2].nodeindex
            xnode = xindices[node.nodeindex]
            ynode = yindices[node.nodeindex]
            leftindices = zeros(Int32, length(xnode))
            rightindices = zeros(Int32, length(xnode))
            for z=1:length(xnode)
                x = xnode[z]
                y = ynode[z]
                keyleft = leftchildindex*dataset.numcols*dataset.numcols + (dataset.subcolumnrefs[leftchildindex,x])*dataset.numcols + dataset.subcolumnrefs[leftchildindex,y]
                keyright = rightchildindex*dataset.numcols*dataset.numcols + (dataset.subcolumnrefs[rightchildindex,x])*dataset.numcols + dataset.subcolumnrefs[rightchildindex,y]
                leftindices[z] = indexdict[leftchildindex][keyleft]
                rightindices[z] = indexdict[rightchildindex][keyright]
            end
            leftrightindices[node.nodeindex] = (leftindices,rightindices)
        end
    end

    return indexdict,xindices,yindices,leftrightindices
end

function getindexdict(dataset::Dataset, paired::Array{Int,1})
    alphabet::Int32 = Int32(16)
    nodelist = getnodelist(dataset.root)
    xindices = [Int32[] for node in nodelist]
    yindices = [Int32[] for node in nodelist]
    indexdict = Dict{Int,Int}[Dict{Int,Int}() for node in nodelist]
    for node in nodelist
        xin = xindices[node.nodeindex]
        yin = yindices[node.nodeindex]
        count = 0
        if node.nodeindex == 1
            for x=1:length(paired)
                if paired[x] > x
                    y = paired[x]
                    key = node.nodeindex*dataset.numcols*dataset.numcols + (dataset.subcolumnrefs[node.nodeindex,x])*dataset.numcols + dataset.subcolumnrefs[node.nodeindex,y]
                    if !haskey(indexdict[node.nodeindex], key)
                        push!(xin,Int32(x))
                        push!(yin,Int32(y))
                        indexdict[node.nodeindex][key] = count
                        count += 1
                    end
                end
            end
        else
            parentindex = get(node.parent).nodeindex
            xpar = xindices[parentindex]
            ypar = yindices[parentindex]
            for z=1:length(xpar)
                x = xpar[z]
                y = ypar[z]
                key = node.nodeindex*dataset.numcols*dataset.numcols + (dataset.subcolumnrefs[node.nodeindex,x])*dataset.numcols + dataset.subcolumnrefs[node.nodeindex,y]
                if !haskey(indexdict[node.nodeindex], key)
                    push!(xin,Int32(x))
                    push!(yin,Int32(y))
                    indexdict[node.nodeindex][key] = count
                    count += 1
                end
            end
        end
    end

    leftrightindices = Dict{Int,Tuple{Array{Int32,1},Array{Int32,1}}}()
    for node in nodelist
        if !isleafnode(node)
            leftchildindex = node.children[1].nodeindex
            rightchildindex = node.children[2].nodeindex
            xnode = xindices[node.nodeindex]
            ynode = yindices[node.nodeindex]
            leftindices = zeros(Int32, length(xnode))
            rightindices = zeros(Int32, length(xnode))
            for z=1:length(xnode)
                x = xnode[z]
                y = ynode[z]
                keyleft = leftchildindex*dataset.numcols*dataset.numcols + (dataset.subcolumnrefs[leftchildindex,x])*dataset.numcols + dataset.subcolumnrefs[leftchildindex,y]
                keyright = rightchildindex*dataset.numcols*dataset.numcols + (dataset.subcolumnrefs[rightchildindex,x])*dataset.numcols + dataset.subcolumnrefs[rightchildindex,y]
                leftindices[z] = indexdict[leftchildindex][keyleft]
                rightindices[z] = indexdict[rightchildindex][keyright]
            end
            leftrightindices[node.nodeindex] = (leftindices,rightindices)
        end
    end

    return indexdict,xindices,yindices,leftrightindices
end


indexdict = nothing
xindices = nothing
yindices = nothing
leftrightindices = nothing
function felsensteincuda(dataset::Dataset, params::ModelParameters, museparams::Array{MuseSpecificParameters,1}, maxbasepairdistance::Int=1000000, keepmuseconditionals::Bool=false)

    alphabet::Int32 = Int32(16)
    nodelist = getnodelist(dataset.root)

    leaves = TreeNode[]
    internal = TreeNode[]
    for node in nodelist
        if isleafnode(node)
            push!(leaves,node)
        else
            push!(internal,node)
        end
    end


    global indexdict
    global xindices
    global yindices
    global leftrightindices
    if indexdict == nothing
        indexdict,xindices,yindices,leftrightindices = getindexdict(dataset, maxbasepairdistance)
    end

    dev = CuDevice(0)
    ctx = CuContext(dev)
    #println("Initial Fels ", Mem.used(),"\t",Mem.total())

    md = CuModuleFile(joinpath(@__DIR__,"cuda","felsenstein.ptx"))
    cudafelsensteinleaves= CuFunction(md, "_Z19felsensteinleaves16iiPKiS0_PfS1_")
    cudafelsensteinhelper = CuFunction(md, "_Z19felsensteinhelper16iiiiiiPKiS0_PKfS2_S2_Pf")
    cudasumfinal = CuFunction(md, "_Z8sumfinaliiPfS_S_")
    cudastorearr = CuFunction(md, "_Z8storearrifPfS_")
    cudalogsumexparr = CuFunction(md, "_Z12logsumexparrifPffS_")
    blocksize = 1024

    leftrightindicescuda = Dict{Int,Tuple{Mem.Buffer,Mem.Buffer}}()
    for node in nodelist
        if !isleafnode(node)
            leftindices,rightindices = leftrightindices[node.nodeindex]
            leftrightindicescuda[node.nodeindex] = (Mem.upload(leftindices),Mem.upload(rightindices))
        end
    end

    #println("LENGTH = ", length(xindices[1]))
    d_finallogliks =  Mem.alloc(Float32, length(xindices[1]))
    d_museconditionals = nothing

    if keepmuseconditionals
        #println("KEEP CONDITIONALS")
        d_museconditionals = Mem.Buffer[Mem.alloc(Float32, length(xindices[1])) for musespecificparams in museparams]
    end

    nodelengths = zeros(Int, length(nodelist))
    #tic()
    store = Dict{Int,Mem.Buffer}()
    paramindex = 1
    for siteCat1=1:params.siteCats
        for siteCat2=1:params.siteCats
            for musespecificparams in museparams
                #println("Start\t",paramindex,"\t",Mem.used(),"\t",Mem.total())
                freqsflattened = Float32[]
                musemodel = MuseModel(params.freqs, getGC(params,musespecificparams), getAT(params,musespecificparams), getGT(params,musespecificparams), params.q1, params.q2, params.q3, params.q4, params.q5, params.q6, params.siteRates[siteCat1], params.siteRates[siteCat2])
                append!(freqsflattened, musemodel.freqs)
                transprobs = gettransitionmatriceslist(params.branchlengths, musemodel.Q)

                d_freqs = Mem.upload(freqsflattened)
                transprobsflattened = Float32[]
                for node in nodelist
                    for a=1:alphabet
                        append!(transprobsflattened, transprobs[node.nodeindex][a,:])
                    end
                end
                d_transprobs = Mem.upload(transprobsflattened)

                stack = Int[1]
                completed = Dict{Int,Int}()

                while length(stack) > 0
                    nodeindex = stack[end]
                    node = nodelist[nodeindex]
                    #println("node",nodeindex,"\t",Mem.used(),"\t",Mem.total())
                    #println(nodelengths)

                    if isleafnode(node)
                        completednode = pop!(stack)
                        completed[completednode] = completednode

                        if !haskey(store,nodeindex)
                            datalen = length(xindices[nodeindex])
                            store[nodeindex] = Mem.alloc(Float32, datalen*(alphabet+1))
                            nodelengths[node.nodeindex] = datalen

                            data = Float32[]
                            for c=1:dataset.numcols
                                append!(data, dataset.data[node.data.seqindex, c, :])
                            end
                            d_data = Mem.upload(data)
                            d_x = Mem.upload(convert(Array{Int32,1}, xindices[nodeindex].-1))
                            d_y = Mem.upload(convert(Array{Int32,1}, yindices[nodeindex].-1))
                            cudacall(cudafelsensteinleaves, (Int32, Int32, Ptr{Int32}, Ptr{Int32}, Ptr{Float32}, Ptr{Float32},), Int32(dataset.numcols), Int32(datalen), d_x, d_y, d_data, store[nodeindex], blocks=div(datalen+blocksize-1, blocksize), threads=blocksize)
                            Mem.free(d_x)
                            Mem.free(d_y)
                        end
                    else
                        leftchildindex = node.children[1].nodeindex
                        rightchildindex = node.children[2].nodeindex

                        cont = true
                        if !haskey(completed,leftchildindex)
                            push!(stack, leftchildindex)
                            cont = false
                        end
                        if !haskey(completed,rightchildindex)
                            push!(stack, rightchildindex)
                            cont = false
                        end

                        if cont
                            d_leftindices, d_rightindices = leftrightindicescuda[nodeindex]
                            datalen = length(leftrightindices[node.nodeindex][1])
                            nodelengths[node.nodeindex] = datalen


                            d_left = store[leftchildindex]
                            d_right = store[rightchildindex]

                            d_res = nothing
                            keeparr = 100000
                            if haskey(store,nodeindex) && datalen*(alphabet+1) < keeparr
                                d_res = store[nodeindex]
                            else
                                d_res = Mem.alloc(Float32, datalen*(alphabet+1))
                            end

                            cudacall(cudafelsensteinhelper, (Int32,Int32,Int32, Int32, Int32, Int32, Ptr{Int32}, Ptr{Int32}, Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Ptr{Float32}), Int32(dataset.numcols), Int32(datalen), Int32(length(nodelist)), Int32(nodeindex-1), Int32(leftchildindex-1), Int32(rightchildindex-1), d_leftindices, d_rightindices, d_transprobs, d_left, d_right, d_res, blocks=div(datalen+blocksize-1, blocksize), threads=blocksize)
                            store[nodeindex] = d_res

                            completednode = pop!(stack)
                            completed[completednode] = completednode

                            if !isleafnode(node.children[1])
                                #leftdatalen = length(leftrightindices[leftchildindex][1])
                                if nodelengths[leftchildindex]*(alphabet+1) >= keeparr
                                    Mem.free(d_left)
                                    delete!(store, leftchildindex)
                                end
                            end
                            if !isleafnode(node.children[2])
                                if nodelengths[rightchildindex]*(alphabet+1) >= keeparr
                                    Mem.free(d_right)
                                    delete!(store, rightchildindex)
                                end
                            end

                        end
                    end
                end

                datalen = length(xindices[1])

                d_logliks =  Mem.alloc(Float32, datalen)
                cudacall(cudasumfinal, (Int32,Int32,Ptr{Float32},Ptr{Float32}, Ptr{Float32}), alphabet, Int32(datalen), d_freqs, store[1], d_logliks, blocks=div(datalen+blocksize-1, blocksize), threads=blocksize)
                if keepmuseconditionals
                    if  siteCat1 == 1 && siteCat2 == 1
                        logw = log(params.siteWeights[siteCat1]) + log(params.siteWeights[siteCat2]) + musespecificparams.logprob
                        cudacall(cudastorearr, (Int32,Float32,Ptr{Float32},Ptr{Float32}), Int32(datalen), Float32(logw), d_museconditionals[musespecificparams.lambdacat], d_logliks, blocks=div(datalen+blocksize-1, blocksize), threads=blocksize)
                    else
                        logw1 = 0.0
                        logw2 = log(params.siteWeights[siteCat1]) + log(params.siteWeights[siteCat2]) + musespecificparams.logprob
                        cudacall(cudalogsumexparr, (Int32,Float32,Ptr{Float32},Float32,Ptr{Float32}), Int32(datalen), Float32(logw1), d_museconditionals[musespecificparams.lambdacat], Float32(logw2), d_logliks, blocks=div(datalen+blocksize-1, blocksize), threads=blocksize)
                    end
                end

                if paramindex == 1
                    logw = log(params.siteWeights[siteCat1]) + log(params.siteWeights[siteCat2]) + musespecificparams.logprob
                    cudacall(cudastorearr, (Int32,Float32,Ptr{Float32},Ptr{Float32}), Int32(datalen), Float32(logw), d_finallogliks, d_logliks, blocks=div(datalen+blocksize-1, blocksize), threads=blocksize)
                else
                    logw1 = 0.0
                    logw2 = log(params.siteWeights[siteCat1]) + log(params.siteWeights[siteCat2]) + musespecificparams.logprob
                    cudacall(cudalogsumexparr, (Int32,Float32,Ptr{Float32},Float32,Ptr{Float32}), Int32(datalen), Float32(logw1), d_finallogliks, Float32(logw2), d_logliks, blocks=div(datalen+blocksize-1, blocksize), threads=blocksize)
                end
                Mem.free(d_logliks)
                Mem.free(store[1])
                #delete!(store, 1)
                Mem.free(d_freqs)
                Mem.free(d_transprobs)

                #println("End\t",paramindex,"\t",Mem.used(),"\t",Mem.total())
                paramindex += 1
            end
        end
    end
    #println("D1")
    finallogliks = Mem.download(Float32, d_finallogliks, length(xindices[1]))
    #println("D2")
    mat = ones(Float64, dataset.numcols, dataset.numcols)*-Inf
    for x=1:dataset.numcols
        yend = min(x+maxbasepairdistance,dataset.numcols)
        for y=x+1:yend
            if dataset.maxbasepairprobs[x,y] > 0.0
                key = 1*dataset.numcols*dataset.numcols + (dataset.subcolumnrefs[1,x])*dataset.numcols + dataset.subcolumnrefs[1,y]
                if haskey(indexdict[1],key)
                    index = indexdict[1][key]+1
                    mat[x,y] = finallogliks[index]
                    mat[y,x] = mat[x,y]
                end
            end
        end
    end
    #println("D3")

    ret = Array{Float64,2}[]
    if keepmuseconditionals
        for z=1:length(d_museconditionals)
            conditionalmat = ones(Float64, dataset.numcols, dataset.numcols)*-Inf
            finallogliks = Mem.download(Float32, d_museconditionals[z], length(xindices[1]))
            for x=1:dataset.numcols
                for y=x+1:dataset.numcols
                    if dataset.maxbasepairprobs[x,y] > 0.0
                        key = 1*dataset.numcols*dataset.numcols + (dataset.subcolumnrefs[1,x])*dataset.numcols + dataset.subcolumnrefs[1,y]
                        if haskey(indexdict[1],key)
                            index = indexdict[1][key]+1
                            conditionalmat[x,y] = finallogliks[index]
                            conditionalmat[y,x] = conditionalmat[x,y]
                        end
                    end
                end
            end
            Mem.free(d_museconditionals[z])
            push!(ret, conditionalmat)
        end
    end
    Mem.free(d_finallogliks)
    #println("D4")

    keylist = Int[k for k in keys(store)]
    for k in keylist
        #Mem.free(store[k])
        #delete!(store, k)
    end
    #println("D5")

    #println("End  ", Mem.used(),"\t",Mem.total())
    GC.gc()
    destroy!(ctx)
    synchronize(ctx)
    #unsafe_reset!(dev)
    #elapsed = toc()
    #println("CUDA ",elapsed)

    return mat, ret
end

function felsensteinposteriorsiterateconditionalscuda(singleprobs::Array{Float64,1}, pairprobs::Array{Float64,2}, dataset::Dataset, params::ModelParameters, museparams::Array{MuseSpecificParameters,1}, maxbasepairdistance::Int=1000000, keepmuseconditionals::Bool=false)
    alphabet::Int32 = Int32(16)
    nodelist = getnodelist(dataset.root)

    leaves = TreeNode[]
    internal = TreeNode[]
    for node in nodelist
        if isleafnode(node)
            push!(leaves,node)
        else
            push!(internal,node)
        end
    end


    global indexdict
    global xindices
    global yindices
    global leftrightindices
    if indexdict == nothing
        indexdict,xindices,yindices,leftrightindices = getindexdict(dataset, maxbasepairdistance)
    end

    dev = CuDevice(0)
    ctx = CuContext(dev)


    md = CuModuleFile(joinpath(@__DIR__,"cuda","felsenstein.ptx"))
    cudafelsensteinleaves= CuFunction(md, "_Z19felsensteinleaves16iiPKiS0_PfS1_")
    cudafelsensteinhelper = CuFunction(md, "_Z19felsensteinhelper16iiiiiiPKiS0_PKfS2_S2_Pf")
    cudasumfinal = CuFunction(md, "_Z8sumfinaliiPfS_S_")
    cudastorearr = CuFunction(md, "_Z8storearrifPfS_")
    cudalogsumexparr = CuFunction(md, "_Z12logsumexparrifPffS_")
    blocksize = 1024

    leftrightindicescuda = Dict{Int,Tuple{Mem.Buffer,Mem.Buffer}}()
    for node in nodelist
        if !isleafnode(node)
            leftindices,rightindices = leftrightindices[node.nodeindex]
            leftrightindicescuda[node.nodeindex] = (Mem.upload(leftindices),Mem.upload(rightindices))
        end
    end

    siterateconditionals = ones(Float64,params.siteCats,dataset.numcols)*-Inf
    refs = []
    for rateCat=1:params.siteCats
        #ref = @spawn computeunpairedlikelihoodscat(dataset, params, Int[rateCat for i=1:dataset.numcols], Int[i for i=1:dataset.numcols], rateCat)
        ref = computeunpairedlikelihoodscat(dataset, params, Int[rateCat for i=1:dataset.numcols], Int[i for i=1:dataset.numcols], rateCat)
        push!(refs,ref)
    end

    for rateCat=1:params.siteCats
        temp = refs[rateCat]
        #temp = @fetch(refs[rateCat])
        for col=1:dataset.numcols
            if temp[col] != -Inf
                siterateconditionals[rateCat,col] =  logsumexp(siterateconditionals[rateCat, col], log(params.siteWeights[rateCat]) + log(singleprobs[col]) + temp[col])
            end
        end
    end

    #tic()
    store = Dict{Int,Mem.Buffer}()
    paramindex = 1
    for siteCat1=1:params.siteCats
        for siteCat2=1:params.siteCats
            for musespecificparams in museparams
                freqsflattened = Float32[]
                musemodel = MuseModel(params.freqs, getGC(params,musespecificparams), getAT(params,musespecificparams), getGT(params,musespecificparams), params.q1, params.q2, params.q3, params.q4, params.q5, params.q6, params.siteRates[siteCat1], params.siteRates[siteCat2])
                append!(freqsflattened, musemodel.freqs)
                transprobs = gettransitionmatriceslist(params.branchlengths, musemodel.Q)

                d_freqs = Mem.upload(freqsflattened)
                transprobsflattened = Float32[]
                for node in nodelist
                    for a=1:alphabet
                        append!(transprobsflattened, transprobs[node.nodeindex][a,:])
                    end
                end
                d_transprobs = Mem.upload(transprobsflattened)

                stack = Int[1]
                completed = Dict{Int,Int}()

                while length(stack) > 0
                    nodeindex = stack[end]
                    node = nodelist[nodeindex]

                    if isleafnode(node)
                        completednode = pop!(stack)
                        completed[completednode] = completednode

                        if !haskey(store,nodeindex)
                            datalen = length(xindices[nodeindex])
                            store[nodeindex] = Mem.alloc(Float32, datalen*(alphabet+1))

                            data = Float32[]
                            for c=1:dataset.numcols
                                append!(data, dataset.data[node.data.seqindex, c, :])
                            end
                            d_data = Mem.upload(data)
                            d_x = Mem.upload(convert(Array{Int32,1}, xindices[nodeindex].-1))
                            d_y = Mem.upload(convert(Array{Int32,1}, yindices[nodeindex].-1))
                            cudacall(cudafelsensteinleaves, (Int32, Int32, Ptr{Int32}, Ptr{Int32}, Ptr{Float32}, Ptr{Float32}), Int32(dataset.numcols), Int32(datalen), d_x, d_y, d_data, store[nodeindex],  blocks=div(datalen+blocksize-1, blocksize), threads=blocksize)
                            Mem.free(d_data)
                        end
                    else
                        leftchildindex = node.children[1].nodeindex
                        rightchildindex = node.children[2].nodeindex

                        cont = true
                        if !haskey(completed,leftchildindex)
                            push!(stack, leftchildindex)
                            cont = false
                        end
                        if !haskey(completed,rightchildindex)
                            push!(stack, rightchildindex)
                            cont = false
                        end

                        if cont
                            d_leftindices, d_rightindices = leftrightindicescuda[nodeindex]
                            datalen = length(leftrightindices[node.nodeindex][1])


                            d_left = store[leftchildindex]
                            d_right = store[rightchildindex]

                            d_res = nothing
                            keeparr = 100000
                            if haskey(store,nodeindex) && datalen*(alphabet+1) < keeparr
                                d_res = store[nodeindex]
                            else
                                d_res = Mem.alloc(Float32, datalen*(alphabet+1))
                            end

                            cudacall(cudafelsensteinhelper, (Int32,Int32,Int32, Int32, Int32, Int32, Ptr{Int32}, Ptr{Int32}, Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Ptr{Float32}), Int32(dataset.numcols), Int32(datalen), Int32(length(nodelist)), Int32(nodeindex-1), Int32(leftchildindex-1), Int32(rightchildindex-1), d_leftindices, d_rightindices, d_transprobs, d_left, d_right, d_res, blocks=div(datalen+blocksize-1, blocksize), threads=blocksize)
                            store[nodeindex] = d_res

                            completednode = pop!(stack)
                            completed[completednode] = completednode

                            if !isleafnode(node.children[1])
                                if length(xindices[leftchildindex])*(alphabet+1) >= keeparr
                                    Mem.free(d_left)
                                    delete!(store, leftchildindex)
                                end
                            end
                            if !isleafnode(node.children[2])
                                if length(xindices[rightchildindex])*(alphabet+1) >= keeparr
                                    Mem.free(d_right)
                                    delete!(store, rightchildindex)
                                end
                            end

                        end
                    end
                end

                datalen = length(xindices[1])
                d_logliks =  Mem.alloc(Float32, datalen)
                cudacall(cudasumfinal, (Int32,Int32,Ptr{Float32},Ptr{Float32}, Ptr{Float32}), alphabet, Int32(datalen), d_freqs, store[1], d_logliks, blocks=div(datalen+blocksize-1, blocksize), threads=blocksize)
                Mem.free(store[1])
                catlogprob = log(params.siteWeights[siteCat1]) + log(params.siteWeights[siteCat2]) + musespecificparams.logprob
                condliks = Mem.download(Float32, d_logliks, datalen)
                Mem.free(d_logliks)
                for x=1:dataset.numcols
                    yend = min(x+maxbasepairdistance,dataset.numcols)
                    for y=x+1:yend
                        if dataset.maxbasepairprobs[x,y] > 0.0
                            key = 1*dataset.numcols*dataset.numcols + (dataset.subcolumnrefs[1,x])*dataset.numcols + dataset.subcolumnrefs[1,y]
                            if haskey(indexdict[1],key)
                                index = indexdict[1][key]+1
                                siterateconditionals[siteCat1,x] = logsumexp(siterateconditionals[siteCat1,x], log(pairprobs[x,y]) + catlogprob+convert(Float64, condliks[index]))
                                siterateconditionals[siteCat2,y] = logsumexp(siterateconditionals[siteCat2,y], log(pairprobs[x,y]) + catlogprob+convert(Float64, condliks[index]))
                            end
                        end
                    end
                end
                Mem.free(d_freqs)
                Mem.free(d_transprobs)
                paramindex += 1
            end
        end
    end
    GC.gc()
    destroy!(ctx)
    synchronize(ctx)
    #unsafe_reset!(dev)
    #elapsed = toc()
    #println("CUDA ",elapsed)

    return siterateconditionals
end



function felsensteincudapaired(dataset::Dataset, paired::Array{Int,1}, params::ModelParameters, museparams::Array{MuseSpecificParameters,1})
    #tic()
    alphabet::Int32 = Int32(16)
    nodelist = getnodelist(dataset.root)

    leaves = TreeNode[]
    internal = TreeNode[]
    for node in nodelist
        if isleafnode(node)
            push!(leaves,node)
        else
            push!(internal,node)
        end
    end

    indexdict,xindices,yindices,leftrightindices = getindexdict(dataset, paired)
    if length(indexdict[1]) == 0
        return 0.0
    end
    #=
    for (xin, yin) in zip(xindices,yindices)
    println("A",length(xin),"\t",length(yin))
end=#

dev = CuDevice(0)
ctx = CuContext(dev)
dummy = Mem.alloc(Float32,1)

md = CuModuleFile(joinpath(@__DIR__,"cuda","felsenstein.ptx"))
cudafelsensteinleaves= CuFunction(md, "_Z25felsensteinleaves16pairediiiPKiS0_PfS1_")
cudafelsensteinhelper = CuFunction(md, "_Z25felsensteinhelper16pairediiiiiiiiiPKiS0_PKfS2_S2_Pf")
cudasumfinal = CuFunction(md, "_Z14sumfinalpairediiiPfS_S_")
cudastorearr = CuFunction(md, "_Z8storearrifPfS_")
cudalogsumexparr = CuFunction(md, "_Z12logsumexparrifPffS_")
cudasumcats = CuFunction(md, "_Z7sumcatsiiPfS_S_")

blocksize = 1024


leftrightindicescuda = Dict{Int,Tuple{Mem.Buffer,Mem.Buffer}}()
for node in nodelist
    if !isleafnode(node)
        leftindices,rightindices = leftrightindices[node.nodeindex]
        leftrightindicescuda[node.nodeindex] = (Mem.upload(leftindices),Mem.upload(rightindices))
    end
end


d_finallogliks =  Mem.alloc(Float32, length(xindices[1]))

#elapsed = toc()

numratecats = 0
freqsflattened = Float32[]
transprobsflattened = Float32[]
paramlogweights = Float32[]
for siteCat1=1:params.siteCats
    for siteCat2=1:params.siteCats
        for musespecificparams in museparams
            musemodel = MuseModel(params.freqs, getGC(params,musespecificparams), getAT(params,musespecificparams), getGT(params,musespecificparams), params.q1, params.q2, params.q3, params.q4, params.q5, params.q6, params.siteRates[siteCat1], params.siteRates[siteCat2])
            append!(freqsflattened, musemodel.freqs)
            transprobs = gettransitionmatriceslist(params.branchlengths, musemodel.Q)
            for node in nodelist
                for a=1:alphabet
                    append!(transprobsflattened, transprobs[node.nodeindex][a,:])
                end
            end
            logw = log(params.siteWeights[siteCat1]) + log(params.siteWeights[siteCat2]) + musespecificparams.logprob
            push!(paramlogweights, Float32(logw))
            numratecats += 1
        end
    end
end
d_freqsflattened =  Mem.upload(freqsflattened)
d_transprobsflattened =  Mem.upload(transprobsflattened)


#tic()
store = Dict{Int,Mem.Buffer}()
stack = Int[1]
completed = Dict{Int,Int}()
while length(stack) > 0
    nodeindex = stack[end]
    node = nodelist[nodeindex]

    if isleafnode(node)
        completednode = pop!(stack)
        completed[completednode] = completednode

        if !haskey(store,nodeindex)
            numpairs = length(xindices[nodeindex])
            datalen = numratecats*numpairs
            store[nodeindex] = Mem.alloc(Float32, datalen*(alphabet+1))

            #println("A",numpairs)
            #println("B",datalen)

            data = Float32[]
            for c=1:dataset.numcols
                append!(data, dataset.data[node.data.seqindex, c, :])
            end
            d_data = Mem.upload(data)
            d_x = Mem.upload(convert(Array{Int32,1}, xindices[nodeindex].-1))
            d_y = Mem.upload(convert(Array{Int32,1}, yindices[nodeindex].-1))
            cudacall(cudafelsensteinleaves, (Int32, Int32, Int32, Ptr{Int32}, Ptr{Int32}, Ptr{Float32}, Ptr{Float32}), Int32(dataset.numcols), Int32(numratecats), Int32(numpairs), d_x, d_y, d_data, store[nodeindex], blocks=div(datalen+blocksize-1, blocksize), threads=blocksize)
            Mem.free(d_data)
            Mem.free(d_x)
            Mem.free(d_y)
        end
    else
        leftchildindex = node.children[1].nodeindex
        rightchildindex = node.children[2].nodeindex

        cont = true
        if !haskey(completed,leftchildindex)
            push!(stack, leftchildindex)
            cont = false
        end
        if !haskey(completed,rightchildindex)
            push!(stack, rightchildindex)
            cont = false
        end

        if cont

            d_leftindices, d_rightindices = leftrightindicescuda[nodeindex]
            numpairs = length(leftrightindices[node.nodeindex][1])
            datalen = numratecats*numpairs
            #println("C",numpairs)
            #println("D",datalen)

            d_left = store[leftchildindex]
            d_right = store[rightchildindex]
            d_res = Mem.alloc(Float32, datalen*(alphabet+1))
            leftnumpairs = div(length(leftrightindices[node.nodeindex][1]),17*numratecats)
            rightnumpairs = div(length(leftrightindices[node.nodeindex][2]),17*numratecats)

            cudacall(cudafelsensteinhelper, (Int32,Int32,Int32,Int32, Int32,Int32, Int32, Int32, Int32, Ptr{Int32}, Ptr{Int32}, Ptr{Float32}, Ptr{Float32}, Ptr{Float32}, Ptr{Float32}), Int32(dataset.numcols), Int32(numratecats), Int32(numpairs), Int32(leftnumpairs), Int32(rightnumpairs), Int32(length(nodelist)), Int32(nodeindex-1), Int32(leftchildindex-1), Int32(rightchildindex-1), d_leftindices, d_rightindices, d_transprobsflattened, d_left, d_right, d_res, blocks=div(datalen+blocksize-1, blocksize), threads=blocksize)
            store[nodeindex] = d_res

            completednode = pop!(stack)
            completed[completednode] = completednode

            Mem.free(d_left)
            Mem.free(d_right)

        end
    end
end

numpairs = length(xindices[1])
datalen = numratecats*numpairs

d_logliks =  Mem.alloc(Float32, datalen)
cudacall(cudasumfinal, (Int32,Int32,Int32,Ptr{Float32},Ptr{Float32}, Ptr{Float32}), alphabet, Int32(numratecats), Int32(numpairs), d_freqsflattened, store[1], d_logliks, blocks=div(datalen+blocksize-1, blocksize), threads=blocksize)
Mem.free(d_freqsflattened)
Mem.free(d_transprobsflattened)
d_paramlogweights = Mem.upload(paramlogweights)
d_finallogliks =  Mem.alloc(Float32, numpairs)
cudacall(cudasumcats, (Int32,Int32,Ptr{Float32},Ptr{Float32}, Ptr{Float32}), Int32(numratecats), Int32(numpairs), d_paramlogweights, d_logliks, d_finallogliks, blocks=div(numpairs+blocksize-1, blocksize), threads=blocksize)

finallogliks = Mem.download(Float32, d_finallogliks, numpairs)
Mem.free(d_finallogliks)
Mem.free(d_logliks)
Mem.free(store[1])
Mem.free(d_paramlogweights)
GC.gc()
destroy!(ctx)
synchronize(ctx)
#unsafe_reset!(dev)

pairedll = 0.0
for x=1:length(paired)
    if paired[x] > x
        y = paired[x]
        key = 1*dataset.numcols*dataset.numcols + (dataset.subcolumnrefs[1,x])*dataset.numcols + dataset.subcolumnrefs[1,y]
        pairedll += finallogliks[indexdict[1][key]+1]
    end
end
return pairedll
end
