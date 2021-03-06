type ConfusionMatrix
    classes::Vector
    matrix::Matrix{Int}
    accuracy::FloatingPoint
    kappa::FloatingPoint
end

function show(io::IO, cm::ConfusionMatrix)
    print(io, "Classes:  ")
    show(io, cm.classes)
    print(io, "\nMatrix:   ")
    show(io, cm.matrix)
    print(io, "\nAccuracy: ")
    show(io, cm.accuracy)
    print(io, "\nKappa:    ")
    show(io, cm.kappa)
end

function _set_entropy(labels::Vector)
    N = length(labels)
    counts = Dict()
    for i in labels
        counts[i] = get(counts, i, 0) + 1
    end
    entropy = 0
    for i in counts
        v = i[2]
        if v > 0
            entropy += v * log(v)
        end
    end
    entropy /= -N
    entropy += log(N)
    return entropy
end

function _info_gain(labels::Vector, featcur::Vector, d)
    N0 = length(labels0)
    N1 = length(labels1)
    cur_split = featcur .< d
    labels0=labels[cur_split]
    labels1=labels[!cur_split]
    N = N0 + N1
    H = - N0/N * _set_entropy(labels0) - N1/N * _set_entropy(labels1)
    return H
end

function _info_gain{T<:FloatingPoint}(labels::Vector{T}, featcur::Vector, d)
    s1l=0.0
    s1r=0.0
    nl=0
    s2l=0.0
    s2r=0.0
    nr=0
    for i=1:length(labels)
      if (featcur[i]<d)
        s1l=s1l+labels[i]*labels[i]
        s2l=s2l+labels[i]
        nl=nl+1
      else
        s1r=s1r+labels[i]*labels[i]
        s2r=s2r+labels[i]
        nr=nr+1
      end
    end
    loss = s1l - s2l*s2l/nl + s1r - s2r*s2r/nr;
    return -loss
end

function _neg_z1_loss{T<:Real,S<:Any}(labels::Vector{S}, weights::Vector{T})
    missmatches = labels .!= majority_vote(labels)
    loss = sum(weights[missmatches])
    return -loss
end

function _neg_z1_loss{T<:Real,S<:FloatingPoint}(labels::Vector{S}, weights::Vector{T})
    s1=0.0
    s2=0.0
    mv=majority_vote(labels)
    for i=1:length(labels)
      s1=s1+(labels[i]-mv)^2*weights[i]
      s2=s2+weights[i]
    end
    loss = s1/s2*length(labels)
    return -loss
end

function _weighted_error{T<:Real}(actual::Vector, predicted::Vector, weights::Vector{T})
    mismatches = actual .!= predicted
    err = sum(weights[mismatches]) / sum(weights)
    return err
end

function majority_vote(labels::Vector)
    counts = Dict()
    for i in labels
        counts[i] = get(counts, i, 0) + 1
    end
    top_vote = None
    top_count = -Inf
    for i in collect(counts)
        if i[2] > top_count
            top_vote = i[1]
            top_count = i[2]
        end
    end
    return top_vote
end

function majority_vote{T<:FloatingPoint}(labels::Vector{T}) 
     return mean(labels) 
end

function confusion_matrix(actual::Vector, predicted::Vector)
    @assert length(actual) == length(predicted)
    N = length(actual)
    _actual = zeros(Int,N)
    _predicted = zeros(Int,N)
    classes = sort(unique([actual, predicted]))
    N = length(classes)
    for i in 1:N
        _actual[actual .== classes[i]] = i
        _predicted[predicted .== classes[i]] = i
    end
    CM = zeros(Int,N,N)
    for i in zip(_actual, _predicted)
        CM[i[1],i[2]] += 1
    end
    accuracy = trace(CM) / sum(CM)
    prob_chance = (sum(CM,1) * sum(CM,2))[1] / sum(CM)^2
    kappa = (accuracy - prob_chance) / (1.0 - prob_chance)
    return ConfusionMatrix(classes, CM, accuracy, kappa)
end

function _nfoldCV(classifier::Symbol, labels, features, args...)
    nfolds = args[end]
    if nfolds < 2
        return
    end
    if classifier == :tree
        pruning_purity = args[1]
    elseif classifier == :forest
        nsubfeatures = args[1]
        ntrees = args[2]
    elseif classifier == :stumps
        niterations = args[1]
    end
    N = length(labels)
    ntest = ifloor(N / nfolds)
    inds = randperm(N)
    accuracy = zeros(nfolds)
    for i in 1:nfolds
        test_inds = falses(N)
        test_inds[(i - 1) * ntest + 1 : i * ntest] = true
        train_inds = !test_inds
        test_features = features[inds[test_inds],:]
        test_labels = labels[inds[test_inds]]
        train_features = features[inds[train_inds],:]
        train_labels = labels[inds[train_inds]]
        if classifier == :tree
            model = build_tree(train_labels, train_features, 0)
            if pruning_purity < 1.0
                model = prune_tree(model, pruning_purity)
            end
            predictions = apply_tree(model, test_features)
        elseif classifier == :forest
            model = build_forest(train_labels, train_features, nsubfeatures, ntrees)
            predictions = apply_forest(model, test_features)
        elseif classifier == :stumps
            model, coeffs = build_adaboost_stumps(train_labels, train_features, niterations)
            predictions = apply_adaboost_stumps(model, coeffs, test_features)
        end
        cm = confusion_matrix(test_labels, predictions)
        accuracy[i] = cm.accuracy
        println("\nFold ", i)
        println(cm)
    end
    println("\nMean Accuracy: ", mean(accuracy))
    return accuracy
end

nfoldCV_tree(labels::Vector, features::Matrix, pruning_purity::Real, nfolds::Integer)                       = _nfoldCV(:tree, labels, features, pruning_purity, nfolds)
nfoldCV_forest(labels::Vector, features::Matrix, nsubfeatures::Integer, ntrees::Integer, nfolds::Integer)   = _nfoldCV(:forest, labels, features, nsubfeatures, ntrees, nfolds)
nfoldCV_stumps(labels::Vector, features::Matrix, niterations::Integer, nfolds::Integer)                     = _nfoldCV(:stumps, labels, features, niterations, nfolds)

