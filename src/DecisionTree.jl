module DecisionTree

using NumericExtensions
import Base.length, Base.convert, Base.promote_rule, Base.show

export Leaf, Node, print_tree,
       build_stump, build_tree, prune_tree, apply_tree, nfoldCV_tree,
       build_forest, apply_forest, nfoldCV_forest,
       build_adaboost_stumps, apply_adaboost_stumps, nfoldCV_stumps,
       majority_vote, ConfusionMatrix, confusion_matrix

include("measures.jl")

abstract TreeElement

type Leaf <: TreeElement
    majority::Any
    values::Vector
end

type Node <: TreeElement
    featid::Integer
    featval::Any
    left::TreeElement
    right::TreeElement
end

abstract LabelVector{T}<:AbstractArray{T,1}

type ContLabel{T}<:LabelVector{T}
  x::Vector{T}
end

type ClassLabel{T}<:LabelVector{T}
  x::Vector{T}
end

Base.getindex(v::LabelVector,a...)=Base.getindex(v.x,a...)
Base.setindex(v::LabelVector,a...)=Base.getindex(v.x,a...)

convert(::Type{Node}, x::Leaf) = Node(0, nothing, x, Leaf(nothing,[nothing]))
promote_rule(::Type{Node}, ::Type{Leaf}) = Node
promote_rule(::Type{Leaf}, ::Type{Node}) = Node

function length(tree::TreeElement)
    s = split(string(tree), "Leaf")
    return length(s) - 1
end

function print_tree(tree::Leaf, indent::Integer)
    matches = find(tree.values .== tree.majority)
    ratio = string(length(matches)) * "/" * string(length(tree.values))
    println("$(tree.majority) : $(ratio)")
end

function print_tree(tree::Node, indent::Integer)
    println("Feature $(tree.featid), Threshold $(tree.featval)")
    print("    " ^ indent * "L-> ")
    print_tree(tree.left, indent + 1)
    print("    " ^ indent * "R-> ")
    print_tree(tree.right, indent + 1)
end
print_tree(tree::TreeElement) = print_tree(tree, 0)

function _split(labels::LabelVector, features::Matrix, nsubfeatures::Integer, weights::Vector)
    nf = size(features,2)
    ndp= size(features,1)
    best = None
    best_val = -Inf
    if nsubfeatures > 0
        inds = randperm(nf)[1:nsubfeatures]
        nf = nsubfeatures
    else
        inds = [1:nf]
    end
    for i in 1:nf
        featcur=features[:,inds[i]]
        if (ndp>100)
          domain_i = quantile(featcur,linspace(0.01,0.99,99))
        else
          domain_i = sort(unique(featcur))
        end
        for d in domain_i[2:]
            if weights == [0]
            	value = _info_gain(labels, featcur, d)
            else
            	value = _neg_z1_loss(labels, featcur,d,weights)
            end
            if value > best_val
                best_val = value
                best = (inds[i], d)
            end
        end
    end
    if (best!=None)
      (a1,a2)=best
      if all(features[:,a1] .< a2)
        return None
      elseif all(features[:,a1] .>= a2)
        return None
    end
    end
    return best
end

function build_stump(labels::LabelVector, features::Matrix, weights::Vector; mode="classification")
    S = _split(labels, features, 0, weights)
    if S == None
        return Leaf(majority_vote(labels), labels)
    end
    id, thresh = S
    split = features[:,id] .< thresh
    return Node(id, thresh,
                Leaf(majority_vote(labels[split]), labels[split]),
                Leaf(majority_vote(labels[!split]), labels[!split]))
end
build_stump(labels::LabelVector, features::Matrix) = build_stump(labels, features, [0])
build_stump(labels::Vector, features::Matrix; mode="classification") = 
   mode=="regression" ? build_stump(ContLabel(labels), features, [0],mode=mode) : build_stump(ClassLabel(labels), features, [0],mode=mode)


function build_tree(labels::LabelVector, features::Matrix, nsubfeatures::Integer; mode="classification")
    S = _split(labels, features, nsubfeatures, [0])
    if S == None
        return Leaf(majority_vote(labels), labels)
    end
    id, thresh = S
    split = features[:,id] .< thresh
    labels_left = labels[split]
    labels_right = labels[!split]
    pure_left = all(labels_left .== labels_left[1])
    pure_right = all(labels_right .== labels_right[1])
    if pure_right && pure_left
        return Node(id, thresh,
                    Leaf(labels_left[1], labels_left),
                    Leaf(labels_right[1], labels_right))
    elseif pure_left
        return Node(id, thresh,
                    Leaf(labels_left[1], labels_left),
                    build_tree(labels_right,features[!split,:], nsubfeatures))
    elseif pure_right
        return Node(id, thresh,
                    build_tree(labels_left,features[split,:], nsubfeatures),
                    Leaf(labels_right[1], labels_right))
    else
        return Node(id, thresh,
                    build_tree(labels_left,features[split,:], nsubfeatures),
                    build_tree(labels_right,features[!split,:], nsubfeatures))
    end
end
build_tree(labels::LabelVector, features::Matrix; mode="classification") = build_tree(labels, features, 0,mode="classification")
build_tree(labels::Vector, features::Matrix,nsubfeatures::Integer; mode="classification")=
  mode=="classification" ? build_tree(ClassLabel(labels),features,nsubfeatures,mode=mode) : build_tree(ContLabel(labels),features,nsubfeatures,mode=mode)

function prune_tree(tree::TreeElement, purity_thresh::Real)
    function _prune_run(tree::TreeElement, purity_thresh::Real)
        N = length(tree)
        if N == 1        ## a Leaf
            return tree
        elseif N == 2    ## a stump
            all_labels = [tree.left.values, tree.right.values]
            majority = majority_vote(all_labels)
            matches = find(all_labels .== majority)
            purity = length(matches) / length(all_labels)
            if purity >= purity_thresh
                return Leaf(majority, all_labels)
            else
                return tree
            end
        else
            return Node(tree.featid, tree.featval,
                        _prune_run(tree.left, purity_thresh),
                        _prune_run(tree.right, purity_thresh))
        end
    end
    pruned = _prune_run(tree, purity_thresh)
    while length(pruned) < length(tree)
        tree = pruned
        pruned = _prune_run(tree, purity_thresh)
    end
    return pruned
end
prune_tree(tree::TreeElement) = prune_tree(tree, 1.0) ## defaults to 100% purity pruning

function apply_tree(tree::TreeElement, features::Vector)
    if typeof(tree) == Leaf
        return tree.majority
    elseif tree.featval == nothing
        return apply_tree(tree.left, features)
    elseif features[tree.featid] < tree.featval
        return apply_tree(tree.left, features)
    else
        return apply_tree(tree.right, features)
    end
end

function apply_tree(tree::TreeElement, features::Matrix)
    N = size(features,1)
    predictions = Array(Any,N)
    for i in 1:N
        predictions[i] = apply_tree(tree, squeeze(features[i,:],1))
    end
    return predictions
end

function build_forest(labels::LabelVector, features::Matrix, nsubfeatures::Integer=0, ntrees::Integer,mode="classification")
    Nlabels = length(labels)
    #Nsamples = int(0.7 * Nlabels)
    Nsamples=Nlabels
    forest = @parallel (vcat) for i in [1:ntrees]
        inds = rand(1:Nlabels, Nsamples)
        t=build_tree(labels[inds], features[inds,:], nsubfeatures)
        ###OOB
        
    end
    return [forest]
end
build_forest(labels::Vector, features::Matrix, nsubfeatures::Integer=0, ntrees::Integer,mode="classification")=
mode=="classification" ? build_forest(ClassLabel(labels),features,nsubfeatures,mode=mode) : build_forest(ContLabel(labels),features,nsubfeatures,mode=mode)


function apply_forest{T<:TreeElement}(forest::Vector{T}, features::Vector)
    ntrees = length(forest)
    votes = Array(Float64,ntrees)
    for i in 1:ntrees
        votes[i] = apply_tree(forest[i],features)
    end
    
    return majority_vote(votes)
end

function apply_forest{T<:TreeElement}(forest::Vector{T}, features::Matrix)
    N = size(features,1)
    predictions = Array(Any,N)
    for i in 1:N
        predictions[i] = apply_forest(forest, squeeze(features[i,:],1))
    end
    return predictions
end

function build_adaboost_stumps(labels::LabelVector, features::Matrix, niterations::Integer)
    N = length(labels)
    weights = ones(N) / N
    stumps = Node[]
    coeffs = FloatingPoint[]
    for i in 1:niterations
        new_stump = build_stump(labels, features, weights)
        predictions = apply_tree(new_stump, features)
        err = _weighted_error(labels, predictions, weights)
        new_coeff = 0.5 * log((1.0 + err) / (1.0 - err))
        matches = labels .== predictions
        weights[!matches] *= exp(new_coeff)
        weights[matches] *= exp(-new_coeff)
        weights /= sum(weights)
        push!(coeffs, new_coeff)
        push!(stumps, new_stump)
        if err < 1e-6
            break
        end
    end
    return (stumps, coeffs)
end

function apply_adaboost_stumps{T<:TreeElement}(stumps::Vector{T}, coeffs::Vector{FloatingPoint}, features::Vector)
    nstumps = length(stumps)
    counts = Dict()
    for i in 1:nstumps
        prediction = apply_tree(stumps[i], features)
        counts[prediction] = get(counts, prediction, 0.0) + coeffs[i]
    end
    top_prediction = None
    top_count = -Inf
    for i in collect(counts)
        if i[2] > top_count
            top_prediction = i[1]
            top_count = i[2]
        end
    end
    return top_prediction
end

function apply_adaboost_stumps{T<:TreeElement}(stumps::Vector{T}, coeffs::Vector{FloatingPoint}, features::Matrix)
    N = size(features,1)
    predictions = Array(Any,N)
    for i in 1:N
        predictions[i] = apply_adaboost_stumps(stumps, coeffs, squeeze(features[i,:],1))
    end
    return predictions
end

end # module

