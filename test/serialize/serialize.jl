
@testset "Structure" begin

    function serdeser(p::T, convfun = cfun(p)) where T
        iob = PipeBuffer();
        ONNX.writeproto(iob, p)
        return convfun(ONNX.readproto(iob, T()))
    end

    function serdeser(p::ONNX.Proto.ModelProto)
        iob = PipeBuffer();
        onnx(iob, p)
        return ONNXmutable.extract(iob)
    end

    cfun(pt) = ONNX.convert
    cfun(::ONNX.Proto.TensorProto) = ONNX.get_array
    cfun(::ONNX.Proto.GraphProto) = gp -> (ONNX.convert(gp), ONNXmutable.sizes(gp))

    include("onnxruntime.jl")

    @testset "Nodes" begin
        using Statistics
        import ONNXmutable: optype, actfuns, fluxlayers, invariantops
        using NaiveNASflux
        import NaiveNASflux: weights, bias
        import ONNXmutable: AbstractProbe, nextname, newfrom, add!, genname
        struct NodeProbe{F} <: AbstractProbe
            name::String
            namefun::F
            protos::Vector{Any}
        end
        NodeProbe(name, namefun) = NodeProbe(name, namefun, [])
        ONNXmutable.add!(p::NodeProbe, n) = push!(p.protos, n)
        ONNXmutable.nextname(p::NodeProbe) = p.namefun
        ONNXmutable.newfrom(p::NodeProbe, pname, Δshape=nothing) = NodeProbe(pname, p.namefun, p.protos)
        ONNXmutable.newnamestrat(p::NodeProbe, f, pname = name(p)) = NodeProbe(pname, f, p.protos)
        ONNXmutable.name(p::NodeProbe) = p.name

        @testset "Paramfree op $(tc.op) attrs: $(pairs(tc.attr))" for tc in (
            (op=:Relu, attr = Dict(), fd=invariantops),
            (op=:Elu, attr = Dict(), fd=invariantops),
            (op=:Elu, attr = Dict(:alpha => 0.5f0), fd=invariantops),
            (op=:Selu, attr = Dict(), fd=invariantops),
            (op=:Selu, attr = Dict(:alpha => 1.5f0), fd=invariantops),
            (op=:GlobalAveragePool, attr=Dict(), fd=invariantops),
            (op=:MaxPool, attr=Dict(:kernel_shape=>(1,2), :pads=>(2,1), :strides=>(2,2)), fd=fluxlayers),
            (op=:AveragePool, attr=Dict(:kernel_shape=>(3,2), :pads=>(1,0), :strides=>(2,2)), fd=fluxlayers),
            (op=:Dropout, attr=Dict(:ratio => 0.2f0), fd=fluxlayers),
            )

            inprobe = NodeProbe("input", f -> "output")

            outprobe = tc.fd[tc.op](tc.attr)(inprobe)

            @test length(outprobe.protos) == 1

            res = serdeser(outprobe.protos[])

            @test res.input == [name(inprobe)]
            @test res.output == [name(outprobe)]
            @test res.op_type == string(tc.op)
            @test res.name == name(outprobe)

            mexprev(v, x) = x
            mexprev(v, x::Tuple) = reverse(x)
            mexprev(::Val{:pads}, x::Tuple) = ONNXmutable.padexpand(Val(length(x)), x)
            for (k,v) in tc.attr
                for (exp, act) in zip(mexprev(Val(k), v), res.attribute[k])
                    @test exp == act
                end
            end
        end

        @testset "Dims method $(tc.ot)" for tc in (
            (f=cat, dims=1, ndims=2, ot="Concat", axname=:axis),
            (f=mean, dims=(2, 3), ndims=4, ot="ReduceMean", axname=:axes),
            (f=dropdims, dims=(3,), ndims=3, ot="Squeeze", axname=:axes)
            )
            inprobe = NodeProbe("input", f -> "output")
            ONNXmutable.shape(p::NodeProbe) = Tuple(1:tc.ndims)

            outprobe = tc.f(inprobe, dims=tc.dims)

            @test length(outprobe.protos) == 1

            res = serdeser(outprobe.protos[])

            @test res.input == [name(inprobe)]
            @test res.output == [name(outprobe)]
            @test res.op_type == tc.ot
            @test res.name == name(outprobe)
            expdims = tc.dims isa Tuple ? collect(tc.dims) : tc.dims
            @test ONNXmutable.numpy2fluxdim.(res.attribute[tc.axname], tc.ndims) == expdims
        end

        @testset "Reshape" begin
            inprobe = NodeProbe("input", f -> "output")

            shapeout = 1
            function ONNXmutable.newfrom(p::NodeProbe, pname, Δshape::Function)
                shapeout = Δshape((:A, missing, 12))
                return NodeProbe(pname, p.namefun, p.protos)
             end

            outprobe = reshape(inprobe, (0, 3, 2, Colon()))

            @test length(outprobe.protos) == 2

            res = serdeser(outprobe.protos[1])
            newshape = serdeser(outprobe.protos[2])

            @test newshape == [-1, 2, 3, 0]

            @test res.input == [name(inprobe), outprobe.protos[2].name]
            @test res.output == [name(outprobe)]
            @test res.op_type == "Reshape"
            @test res.name == name(outprobe)
            @test ismissing(shapeout[end])
            @test collect(skipmissing(shapeout)) == [:A, 3, 2]
        end

        @testset "Pad expand" begin
            import ONNXmutable: padexpand
            @test padexpand(Val(1), (1,)) == [1,1]
            @test padexpand(Val(2), (1,2)) == [2,1,2,1]
            @test padexpand(Val(3), (1,2,3)) == [3,2,1,3,2,1]

            @test padexpand(Val(1), (1,2)) == [1,2]
            @test padexpand(Val(2), (1,2,3,4)) == [3,1,4,2]
            @test padexpand(Val(3), (1,2,3,4,5,6)) == [5,3,1,6,4,2]
        end

        @testset "$(tc.layer) node" for tc in (
            (layer=Dense(3,4, relu), indata=reshape(collect(Float32, 1:12), :, 4) .- 3),
            (layer=Conv((1,2), 3=>4, relu; pad=(2,1), stride=(1,2), dilation=3), indata=reshape(collect(Float32, 1:3*9*9), 9,9,3,1) .- 10),
            (layer=Conv((2,3), 3=>4, relu; pad=(1,2,3,4), stride=(1,2), dilation=3), indata=reshape(collect(Float32, 1:3*9*9), 9,9,3,1) .- 10),
            )
            ONNXmutable.shape(p::NodeProbe) = missing

            inprobe = NodeProbe("input", genname)

            outprobe = tc.layer(inprobe)

            @test length(outprobe.protos) == 4

            lp,wp,bp,ap = Tuple(outprobe.protos)

            ln = serdeser(lp)
            an = serdeser(ap)
            w = serdeser(wp)
            b = serdeser(bp)

            @test size(w) == size(weights(tc.layer))
            @test size(b) == size(bias(tc.layer))

            @test w ≈ ONNXmutable.flipweights(layertype(tc.layer), weights(tc.layer))
            @test b ≈ bias(tc.layer)

            ln.attribute[:activation] = actfuns[Symbol(optype(an))](an.attribute)
            res = fluxlayers[optype(ln)](ln.attribute, w, b)

            @test string(res) == string(tc.layer)

            resout = res(tc.indata)
            expout = tc.layer(tc.indata)

            @test size(resout) == size(expout)
            @test resout ≈ expout

            ortout, = onnxruntime_infer(tc.layer, tc.indata)
            @test size(ortout) == size(expout)
            @test ortout ≈ expout
        end

        @testset "$(tc.layer) node" for tc in (
            (layer=RNN(3, 5, x -> Flux.elu(x, 0.1f0)), indata = reshape(collect(Float32, 1:12), :, 4) .- 3),
            (layer=LSTM(4, 3), indata = reshape(collect(Float32, 1:12), 4, :) .- 3),
            )
            import NaiveNASflux: hiddenweights

            ONNXmutable.shape(p::NodeProbe) = (missing, nout(tc.layer), missing)
            inprobe = NodeProbe("input", genname)

            outprobe = tc.layer(inprobe)

            @test length(outprobe.protos) == 5

            lp,wip,whp,bp = Tuple(outprobe.protos)

            ln = serdeser(lp)
            wi = serdeser(wip)
            wh = serdeser(whp)
            b = serdeser(bp)

            res = fluxlayers[optype(ln)](ln.attribute, wi, wh, b)

            lt = layertype(tc.layer)
            @test size(weights(res)) == size(weights(tc.layer))
            @test size(hiddenweights(res)) == size(hiddenweights(tc.layer))
            @test size(bias(res)) == size(bias(res))

            @test weights(res) ≈ weights(tc.layer)
            @test hiddenweights(res) ≈ hiddenweights(tc.layer)
            @test bias(res) ≈ bias(res)

            resout = res(tc.indata)
            expout = tc.layer(tc.indata)

            @test size(resout) == size(expout)
            @test resout ≈ expout

            ortout, = onnxruntime_infer(tc.layer, reshape(tc.indata,size(tc.indata)...,1))
            ortout = dropdims(ortout; dims=3)

            @test size(ortout) == size(expout)
            @test ortout ≈ expout
        end

        @testset "$(tc.layer) node" for tc in (
            (layer=BatchNorm(3, relu; initβ = i -> collect(Float32, 1:i), initγ = i -> collect(Float32, i:-1:1), ϵ=1e-3, momentum = 0.78), indata=reshape(collect(Float32, 1:2*3*3), 2,3,3,1) .- 10),
            )

            inprobe = NodeProbe("input", genname)
            outprobe = tc.layer(inprobe)
            @test length(outprobe.protos) == 6

            ln, γ, β, μ, σ², an = Tuple(serdeser.(outprobe.protos))

            @test size(β) == size(tc.layer.β)
            @test size(γ) == size(tc.layer.γ)
            @test size(μ) == size(tc.layer.μ)
            @test size(σ²) == size(tc.layer.σ²)

            @test β ≈ tc.layer.β
            @test γ ≈ tc.layer.γ
            @test μ ≈ tc.layer.μ
            @test σ² ≈ tc.layer.σ²

            ln.attribute[:activation] = actfuns[Symbol(optype(an))](an.attribute)
            res = fluxlayers[optype(ln)](ln.attribute, γ, β, μ, σ²)

            @test string(res) == string(tc.layer)

            resout = res(tc.indata)
            expout = tc.layer(tc.indata)

            @test size(resout) == size(expout)
            @test resout ≈ expout

            ortout, = onnxruntime_infer(tc.layer, tc.indata)
            @test size(ortout) == size(expout)
            @test ortout ≈ expout
        end
    end

    @testset "Graphs" begin
        using NaiveNASflux
        import ONNXmutable: graphproto, modelproto, validate

        dense(name, inpt::AbstractVertex, outsize, actfun=identity) = mutable(name, Dense(nout(inpt), outsize, actfun), inpt)
        dense(inpt::AbstractVertex, outsize, actfun=identity) = mutable(Dense(nout(inpt), outsize, actfun), inpt)

        convvertex(name, inpt::AbstractVertex, outsize, actfun=identity) = mutable(name, Conv((1,1), nout(inpt) => outsize, actfun), inpt)

        bnvertex(name, inpt::AbstractVertex, actfun=identity) = mutable(name, BatchNorm(nout(inpt), actfun), inpt)

        mpvertex(name, inpt::AbstractVertex) = mutable(name, MaxPool((2,2); pad=(1,0), stride=(1,2)), inpt)

        fvertex(name, inpt::AbstractVertex, f) = invariantvertex(f, inpt; traitdecoration = t -> NamedTrait(t, name))

        function test_named_graph(g_org, extradims = ())
            gp_org = graphproto(g_org)
            gp_org.name="testmodel"
            validate(modelproto(;graph=gp_org))
            gt_new, sizes = serdeser(gp_org)

            g_new = CompGraph(gt_new, sizes)

            @test name.(vertices(g_org)) == name.(vertices(g_new))
            @test nout.(vertices(g_org)) == nout.(vertices(g_new))
            @test nin.(vertices(g_org)) == nin.(vertices(g_new))

            outsize = nout(g_org.inputs[1])
            bs = 4
            indata = reshape(collect(Float32, 1:outsize*bs*prod(extradims)), extradims..., outsize, :)

            expout = g_org(indata)
            resout = g_new(indata)

            @test size(expout) == size(resout)
            @test expout ≈ resout

            # For FLux recurrent layers as they accept 2D input but ONNX wants 3D input
            sizediff = length(ONNXmutable.shape(g_new.inputs[])) - ndims(indata)
            indata = reshape(indata, size(indata)..., ones(Int, sizediff)...)

            ortout, = onnxruntime_infer(g_org, indata)
            ortout = dropdims(ortout, dims=Tuple(ndims(ortout)-sizediff+1:ndims(ortout)))

            @test size(ortout) == size(expout)
            @test ortout ≈ expout

            return g_new
        end

        @testset "Generic function" begin
            l1 = Dense(2, 3, elu)
            l2 = Dense(3, 2)
            function f(x, y)
                x1 = l1(x)
                x2 = l2(x1)
                return x2 .+ y
            end

            gp_sizes = graphproto(f, "x" => (2, missing), "y" => (2,))
            g_sizes = CompGraph(serdeser(gp_sizes)...)

            x = reshape(collect(Float32, 1:2*4), 2,4)
            y = Float32[5, 6]

            @test name.(vertices(g_sizes)) == ["x", "dense_0", "dense_1", "y", "add_0"]
            @test nout.(vertices(g_sizes)) == [2, 3, 2, 2, 2]
            @test nin.(vertices(g_sizes)) == [[], [2], [3], [], [2, 2]]

            @test g_sizes(x, y) ≈ f(x,y)

            function f(x)
                x1 = l1(x)
                return l2(x1)
            end

            gp_nosizes =  graphproto(f, "x" => missing)
            g_nosizes = CompGraph(serdeser(gp_nosizes)...)

            @test name.(vertices(g_nosizes)) == ["x", "dense_0", "dense_1"]
            @test g_nosizes(x) ≈ f(x)
        end

        @testset "Linear Dense graph" begin
            v0 = inputvertex("input", 3, FluxDense())
            v1 = dense("dense1", v0, 4, relu)
            v2 = dense("dense2", v1, 5, elu)
            v3 = dense("output", v2, 2)

            test_named_graph(CompGraph(v0, v3))
        end

        @testset "Linear Dense graph without names" begin
            v0 = inputvertex("input", 3, FluxDense())
            v1 = dense(v0, 4, selu)
            v2 = dense(v1, 5, relu)
            v3 = dense(v2, 2)

            g_org = CompGraph(v0, v3)

            gp_org = graphproto(g_org)
            gt_new, sizes = serdeser(gp_org)

            g_new = CompGraph(gt_new, sizes)

            @test name.(vertices(g_new)) == ["input_0", "dense_0", "dense_1", "dense_2"]

            indata = reshape(collect(Float32, 1:3*4), nout(v0), :)
            @test g_org(indata) ≈ g_new(indata)
        end

        @testset "Linear Dense graph non-unique names" begin
            v0 = inputvertex("input", 3, FluxDense())
            v1 = dense("vv", v0, 4, selu)
            v2 = dense("vv", v1, 5, relu)
            g_org = CompGraph(v0, v2)

            gp_org = graphproto(g_org)
            gt_new, sizes = serdeser(gp_org)

            g_new = CompGraph(gt_new, sizes)

            @test name.(vertices(g_new)) == ["input_0", "dense_0", "dense_1",]

            indata = reshape(collect(Float32, 1:3*4), nout(v0), :)
            @test g_org(indata) ≈ g_new(indata)
        end

        @testset "Linear Conv graph" begin
            v0 = inputvertex("input", 3, FluxConv{2}())
            v1 = convvertex("conv1", v0, 4, selu)
            v2 = convvertex("conv2", v1, 5, elu)
            v3 = convvertex("output", v2, 2)

            test_named_graph(CompGraph(v0, v3), (2,3))
        end

        @testset "Linear Conv graph with global pooling" begin
            v0 = inputvertex("input", 3, FluxConv{2}())
            v1 = convvertex("conv1", v0, 4, relu)
            v2 = convvertex("conv2", v1, 5, elu)
            v3 = fvertex("globmeanpool", v2, x -> ONNXmutable.globalmeanpool(x, y -> dropdims(y, dims=(1,2))))
            v4 = dense("output", v3, 2)

            test_named_graph(CompGraph(v0, v4), (2,3))
        end

        @testset "Linear Conv graph with global pooling without names" begin
            v0 = inputvertex("input", 3, FluxConv{2}())
            v1 = convvertex("", v0, 4, relu)
            v2 = invariantvertex(x -> ONNXmutable.globalmeanpool(x, y -> dropdims(y, dims=(1,2))), v1)

            g_org = CompGraph(v0, v2)

            gp_org = graphproto(g_org)
            @test length(size(gp_org.output[])) == 2

            gt_new, ss = serdeser(gp_org)

            g_new = CompGraph(gt_new, ss)
            @test name.(vertices(g_new)) == ["input_0", "conv_0", "globalaveragepool_0"]

            indata = reshape(collect(Float32, 1:3*2*2*2), 2,2,3,2)
            @test size(g_org(indata)) == size(g_new(indata))
            @test g_org(indata) ≈ g_new(indata)
        end

        @testset "Linear Batchnorm and Conv graph with global pooling" begin
            v0 = inputvertex("input", 3, FluxConv{2}())
            v1 = convvertex("conv", v0, 4, relu)
            v2 = bnvertex("batchnorm", v1, elu)
            v3 = fvertex("globmeanpool", v2, x -> ONNXmutable.globalmeanpool(x, y -> dropdims(y, dims=(1,2))))
            v4 = dense("output", v3, 2, selu)

            test_named_graph(CompGraph(v0, v4), (4,6))
        end

        @testset "Linear Conv and MaxPool graph with global pooling" begin
            v0 = inputvertex("input", 3, FluxConv{2}())
            v1 = convvertex("conv", v0, 4, relu)
            v2 = mpvertex("maxpool", v1)
            v3 = fvertex("globmeanpool", v2, x -> ONNXmutable.globalmeanpool(x, y -> dropdims(y, dims=(1,2))))
            v4 = dense("output", v3, 2, selu)

            test_named_graph(CompGraph(v0, v4), (2,3))
        end

        @testset "Dense graph with add" begin
            v0 = inputvertex("input", 3, FluxDense())
            v1 = dense("dense1", v0, 4, relu)
            v2 = dense("dense2", v0, 4)
            v3= "add" >> v1 + v2
            v4 = dense("output", v3, 2, selu)

            test_named_graph(CompGraph(v0, v4))
        end

        @testset "Dense graph with add without names" begin
            v0 = inputvertex("input", 3, FluxDense())
            v1 = dense(v0, 4, relu)
            v2 = dense(v0, 4)
            v3 = v1 + v2

            g_org = CompGraph(v0, v3)

            gp_org = graphproto(g_org)
            gt_new, sizes = serdeser(gp_org)

            g_new = CompGraph(gt_new, sizes)

            @test name.(vertices(g_new)) == ["input_0", "dense_0", "dense_1", "add_0"]

            indata = reshape(collect(Float32, 1:3*4), nout(v0), :)
            @test g_org(indata) ≈ g_new(indata)
        end

        @testset "Dense graph with add and layerfun" begin
            import ONNXmutable: create_vertex_default
            v0 = inputvertex("input", 3, FluxDense())
            v1 = dense(v0, 4, relu)
            v2 = dense(v0, 4)
            v3 = v1 + v2

            g_org = CompGraph(v0, v3)

            gp_org = graphproto(g_org)
            gt_new, sizes = serdeser(gp_org)

            callcnt = 0
            struct CntSpy <: AbstractMutableComp
                f
            end
            function (c::CntSpy)(x...)
                callcnt += 1
                return c.f(x...)
            end
            NaiveNASflux.layer(c::CntSpy) = layer(c.f)

            g_new = CompGraph(gt_new, sizes, (args...) -> create_vertex_default(args...;layerfun=CntSpy))

            indata = reshape(collect(Float32, 1:3*4), nout(v0), :)
            outdata = ones(Float32, nout(v3), size(indata, 2))

            Flux.train!((x,y) -> Flux.mse(g_new(x), y), params(g_new), [(indata, outdata)], Flux.Descent(0.6))
            @test callcnt == nv(g_new) - 1
        end

        @testset "Dense graph with cat" begin
            v0 = inputvertex("input", 3, FluxDense())
            v1 = dense("dense1", v0, 4, elu)
            v2 = dense("dense2", v0, 4)
            v3 = concat("conc", v1, v2)
            v4 = dense("output", v3, 2, relu)

            test_named_graph(CompGraph(v0, v4))
        end

        @testset "Dense graph with cat and layerfun" begin
            v0 = inputvertex("input", 3, FluxDense())
            v1 = dense("dense1", v0, 4, elu)
            v2 = dense("dense2", v0, 4)
            v3 = concat("conc", v1, v2)
            v4 = dense("output", v3, 2, relu)

            g_org = CompGraph(v0, v4)

            gp_org = graphproto(g_org)
            gt_new, sizes = serdeser(gp_org)

            callcnt = 0
            struct CntSpy <: AbstractMutableComp
                f
            end
            function (c::CntSpy)(x...)
                callcnt += 1
                return c.f(x...)
            end
            NaiveNASflux.layer(c::CntSpy) = layer(c.f)

            g_new = CompGraph(gt_new, sizes, (args...) -> create_vertex_default(args...;layerfun=CntSpy))

            indata = reshape(collect(Float32, 1:3*4), nout(v0), :)
            outdata = ones(Float32, nout(v4), size(indata, 2))

            Flux.train!((x,y) -> Flux.mse(g_new(x), y), params(g_new), [(indata, outdata)], Flux.Descent(0.6))
            @test callcnt == nv(g_new) - 1
        end

        @testset "Conv and batchnorm graph with cat" begin
            v0 = inputvertex("input", 3, FluxConv{2}())
            v1 = convvertex("conv", v0, 2, elu)
            v2 = bnvertex("batchnorm", v0)
            v3 = concat("conc", v1, v2)
            v4 = fvertex("globmeanpool", v3, x -> ONNXmutable.globalmeanpool(x, y -> dropdims(y, dims=(1,2))))
            v5 = dense("output", v4, 2, relu)

            test_named_graph(CompGraph(v0, v5), (2,3))
        end

        @testset "Dense graph with cat without names" begin
            v0 = inputvertex("input", 3, FluxDense())
            v1 = dense(v0, 4, relu)
            v2 = dense(v0, 4)
            v3 = concat("conc", v1, v2)

            g_org = CompGraph(v0, v3)

            gp_org = graphproto(g_org)
            gt_new, sizes = serdeser(gp_org)

            g_new = CompGraph(gt_new, sizes)

            @test name.(vertices(g_new)) == ["input_0", "dense_0", "dense_1", "concat_0"]

            indata = reshape(collect(Float32, 1:3*4), nout(v0), :)
            @test g_org(indata) ≈ g_new(indata)
        end

        @testset "RNN to LSTM" begin
            v0 = inputvertex("input", 3, FluxRnn())
            v1 = mutable("rnn", RNN(nout(v0), 4), v0)
            v2 = mutable("lstm", LSTM(nout(v1), 5), v1)

            test_named_graph(CompGraph(v0, v2))
        end

        @testset "Recurrent to Dense" begin
            v0 = inputvertex("input", 3, FluxRnn())
            v1 = mutable("rnn", RNN(nout(v0), 4), v0)
            v2 = mutable("lstm", LSTM(nout(v1), 5), v1)
            v3 = dense("dense", v2, 6, elu)

            g_org = CompGraph(v0, v3)
            g_new = CompGraph(serdeser(graphproto(g_org))...)

            @test name.(vertices(g_new)) == name.(vertices(g_org))

            indata = reshape(collect(Float32, 1:3*5*7), 3,5,7)

            expout = g_org.(Flux.unstack(indata, 3))
            resout = g_new.(Flux.unstack(indata, 3))

            @test size.(expout) == size.(resout)
            @test expout ≈ resout

            ortout, = onnxruntime_infer(g_org, indata)
            expout_s = hcat(expout...)

            @test size.(expout_s) == size.(ortout)
            @test expout_s ≈ ortout
        end

        @testset "Graph two inputs two outputs" begin
            vins = inputvertex.(["in1", "in2"], 3, Ref(FluxDense()))
            v1 = "add" >> vins[1] + vins[2]
            v2 = concat("conc", vins[1], vins[2])

            g_org = CompGraph(vins, [v1, v2])
            g_new = CompGraph(serdeser(graphproto(g_org))...)

            @test name.(vertices(g_org)) == name.(vertices(g_new))

            indata1 = reshape(collect(Float32, 1:3*4), nout(vins[1]), :)
            indata2 = indata1 .* -0.5
            @test g_org(indata1, indata2) == g_new(indata1, indata2)
        end
    end

    @testset "Models" begin
        import ONNXmutable: modelproto

        @testset "Generic function infer" begin
            _f(x, y) = x .+ y
            f(x, y) = _f(x,y)
            f(x::Matrix{Int}, y::Matrix{Int}) = _f(x, y)

            mp = modelproto(f)
            mt, ss = serdeser(mp)

            @test length(ss["data_0"]) == 2
            @test length(ss["data_1"]) == 2

            g = CompGraph(mt, ss)
            g([1,2], [3,4]) == f([1,2], [3,4])
        end

        @testset "CompGraph infer" begin
            vis = inputvertex.("in", [2, 2], Ref(FluxDense()))
            g_org = CompGraph(vis, +(vis...))

            mp = modelproto(g_org)
            mt, ss = serdeser(mp)

            @test length(ss["in_0"]) == 2
            @test length(ss["in_1"]) == 2

            g_new = CompGraph(mt, ss)
            g_org([1,2], [3,4]) == g_new([1,2], [3,4])
        end
    end

    @testset "Save to file" begin
        using NaiveNASflux
        function tryfile(filename, args...; kwargs...)
            try
                onnx(filename, args...; kwargs...)
                return CompGraph(filename)
            finally
                rm(filename;force=true)
            end
        end

        @testset "Generic function no pars" begin
            f = (x,y) -> x + y
            g = tryfile("generic_function_no_pars.onnx", f)
            @test name.(vertices(g)) == ["data_0", "data_1", "add_0"]
            @test g(1,3) == f(1, 3)
        end

        @testset "Generic function sizes" begin
            f = (x,y) -> x + y
            g = tryfile("generic_function_sizes.onnx", f, (2,missing), (2,missing))
            nout.(vertices(g)) == [2, 2]
            @test g([1,3], [2, 4]) == f([1,3], [2, 4])
        end

        @testset "Simple graph no pars" begin
            v0 = inputvertex("in", 3, FluxDense())
            v1 = mutable("dense1", Dense(3, 2, relu), v0)
            v2 = mutable("dense2", Dense(2, 3), v1)
            g_org = CompGraph(v0, v2)

            g_new = tryfile("simple_graph_no_pars.onnx", g_org)

            @test name.(vertices(g_org)) == name.(vertices(g_new))
            @test nout.(vertices(g_org)) == nout.(vertices(g_new))
            @test nin.(vertices(g_org)) == nin.(vertices(g_new))

            indata = reshape(collect(Float32, 1:3*2), 3,2)
            @test g_org(indata) ≈ g_new(indata)
        end

        @testset "Simple graph namestrat" begin
            v0 = inputvertex("in", 3, FluxConv{2}())
            v1 = mutable("conv", Conv((1,2), 3 => 4, relu), v0)
            v2 = mutable("bn", BatchNorm(4, elu), v1)
            g_org = CompGraph(v0, v2)

            ng = ONNXmutable.name_runningnr()
            ns(v::MutationVertex) = n -> ng
            ns(n) = ng(n)

            g_new = tryfile("simple_graph_namestrat.onnx", g_org; namestrat=ns)

            @test name.(vertices(g_new)) == ["in_0", "conv_0", "batchnorm_0"]
            @test nout.(vertices(g_org)) == nout.(vertices(g_new))
            @test nin.(vertices(g_org)) == nin.(vertices(g_new))

            indata = reshape(collect(Float32, 1:1*2*3*4), 1,2,3,4)
            @test g_org(indata) ≈ g_new(indata)
        end
    end
end
