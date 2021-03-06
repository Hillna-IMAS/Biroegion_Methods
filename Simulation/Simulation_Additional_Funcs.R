###################################################################################################################################
## Additional function for running, predicting, diagnosing and exploring community models and their outputs for bioregionalisation
## N.Hill March 2018 with input from S. Woolley, S. Foster
###################################################################################################################################

##################################
## Choosing Clusters ----
##################################

#Choose number of clusters based on average sihouette width (higher values better), Calinski and Harabasz index (CH; higher values better)
# and average stability of groups determined using bootstrap methods (higher values better)

grp_stats<- function(min_grp, max_grp,        # set values for number of groups to be tested
                    tree_clust,               # object output from hclust()
                    dissim,                   # either a dissimilarity/distance matrix of class 'dist' or call to dist() to produce one
                    method)                   # method used for hierarchical clustering (see hclust())
{
  require(fpc)
res<-data.frame(sil=rep(0,(max_grp-min_grp +1)),ch=rep(0,(max_grp-min_grp +1)),boot= rep (0,(max_grp-min_grp +1)), row.names = paste0("grp", min_grp:max_grp))
grps<-min_grp:max_grp

for (i in 1:length(grps)){
  test<-cutree(tree_clust,grps[i])
  test_stats<-cluster.stats(dissim, test)
  test_boot<-clusterboot(data=dissim, B=50, bootmethod="boot",clustermethod=disthclustCBI, method=method, k=grps[i])
  res[i,]<-round(c(test_stats$avg.silwidth, test_stats$ch, mean(test_boot$bootmean)),3)
}
return(res)
}



#################################
## bbGDM ----
#################################


## bbgdm wrapper around gdm
bbgdm <- function(data, geo=FALSE, splines=NULL, knots=NULL, bootstraps=10, ncores=1){
  
  ## generate the number of sites for bayesian bootstrap.
  sitecols <- c('s1.xCoord','s1.yCoord','s2.xCoord','s2.yCoord')
  sitedat <- rbind(as.matrix(data[,sitecols[1:2]]),as.matrix(data[,sitecols[3:4]]))
  nsites <- nrow(sitedat[!duplicated(sitedat[,1:2]),])
  
  mods <- surveillance::plapply(1:bootstraps, bb_apply, nsites, data, geo, splines, knots, .parallel = ncores)
  
  median.intercept <- apply(plyr::ldply(mods, function(x) c(x$intercept)),2,median,na.rm=TRUE)
  quantiles.intercept <- apply(plyr::ldply(mods, function(x) c(x$intercept)),2, function(x) quantile(x,c(.05,.25,.5,.75, .95),na.rm=TRUE))  
  
  median.coefs <- apply(plyr::ldply(mods, function(x) c(x$coefficients)),2,median,na.rm=TRUE)
  quantiles.coefs <- apply(plyr::ldply(mods, function(x) c(x$coefficients)),2, function(x) quantile(x,c(.05,.25,.5,.75, .95),na.rm=TRUE))
  results <- list(gdms=mods,
                  median.intercept=median.intercept,
                  quantiles.intercept=quantiles.intercept,
                  median.coefs=median.coefs,
                  quantiles.coefs=quantiles.coefs)
  class(results) <- c("bbgdm", "list")
  return(results)
}

bb_apply <- function(x,nsites,data,geo,splines,knots){
  
  # creates the weights for bayes boot
  w <- gtools::rdirichlet(nsites, rep(1/nsites,nsites))
  wij <- w%*%t(w)
  wij <- wij[upper.tri(wij)]
  tmp <- data
  tmp$weights <- wij
  x <- gdm(tmp, geo=geo, splines=splines, knots=knots)
  return(x)
}

## function for predicting dissimilarities
predict_gdm <- function(mod, newobs, bbgdm=TRUE){
  
  # newobs <- bbgdm::diff_table_cpp(as.matrix(newdat))
  # newobs <- data.frame(dissim=0,weights=0,s1.x=0,s1.Y=0,s2.X=0,s2.Y=0,newobs)
  
  if(isTRUE(bbgdm)){
    predicted <- rep(0,times=nrow(newobs))
    object <- mod$gdms[[1]]
    knots <- mod$gdms[[1]]$knots
    splineNo <- mod$gdms[[1]]$splines
    intercept <- mod$median.intercept 
    coefs <- mod$median.coefs
    
    pred <- .C( "GDM_PredictFromTable",
                as.matrix(newobs),
                as.integer(FALSE),
                as.integer(length(object$predictors)), 
                as.integer(nrow(newobs)), 
                as.double(knots),
                as.integer(splineNo),
                as.double(c(intercept,coefs)),
                preddata = as.double(predicted),
                PACKAGE = "gdm")
    
  } else{
    predicted <- rep(0,times=nrow(newobs))
    object <- mod
    knots <- object$knots
    splineNo <- object$splines
    intercept <- object$intercept 
    coefs <- object$coefficients
    
    pred <- .C( "GDM_PredictFromTable",
                as.matrix(newobs),
                as.integer(FALSE),
                as.integer(length(object$predictors)), 
                as.integer(nrow(newobs)), 
                as.double(knots),
                as.integer(splineNo),
                as.double(c(intercept,coefs)),
                preddata = as.double(predicted),
                PACKAGE = "gdm")
  }
  
  # class(pred$preddata)='dist'
  # attr(pred$preddata,"Size")<-nrow(sim_dat) # bug here sorry about that should have been 'newdat'
  # pred <- as.dist(pred$preddata)
  pred$preddata
  
}



## Cluster based on the transformed environment.
## function that does this based on the bbgdm function:
bbgdm.transform <- function(model, data){
  #################
  ##lines used to quickly test function
  #model <- gdmModel 
  #data <- climCurrExt
  #data <- cropRasts[[3:nlayers(cropRasts)]]
  #################
  options(warn.FPU = FALSE)
  rastDat <- NULL
  dataCheck <- class(data)
  
  ##error checking of inputs
  ##checks to make sure a gdm model is given
  if(class(model)[1]!="bbgdm"){
    stop("model argument must be a gdm model object")
  }
  ##checks to make sure data is a correct format
  if(!(dataCheck=="RasterStack" | dataCheck=="RasterLayer" | dataCheck=="RasterBrick" | dataCheck=="data.frame")){
    stop("Data to be transformed must be either a raster object or data frame")
  }
  
  ##checks rather geo was T or F in the model object
  geo <- model$gdms[[1]]$geo
  
  ##turns raster data into dataframe
  if(dataCheck=="RasterStack" | dataCheck=="RasterLayer" | dataCheck=="RasterBrick"){
    ##converts the raster object into a dataframe, for the gdm transformation
    rastDat <- data
    data <- rasterToPoints(rastDat)
    ##determines the cell number of the xy coordinates
    rastCells <- cellFromXY(rastDat, xy=data[,1:2]) 
    
    ##checks for NA in the 
    checkNAs <- as.data.frame(which(is.na(data), arr.ind=T))
    if(nrow(checkNAs)>0){
      warning("After extracting raster data, NAs found from one or more layers. Removing NAs from data object to be transformed.")
      data <- na.omit(data)
      rastCells <- rastCells[-c(checkNAs$row)]
    }
    
    ##if geo was not T in the model, removes the coordinates from the data frame
    if(geo==FALSE){
      data <- data[,3:ncol(data)]
    }
  }
  
  sizeVal <- 10000000
  ##sets up the data to be transformed into pieces to be transformed
  holdData <- data
  fullTrans <- matrix(0,nrow(holdData),ncol(holdData))
  rows <- nrow(holdData)
  istart <- 1
  iend <- min(sizeVal,rows)
  ##to prevent errors in the transformation of the x and y values when geo is a predictor,
  ##extracts the rows with the minimum and maximum x and y values, these rows will be added
  ##onto the "chuck" given to transform, and then immediately removed after the transformation,
  ##this makes sure that the c++ code will always have access to the minimum and maximum 
  ##x and y values
  if(geo==TRUE){
    if(dataCheck=="RasterStack" | dataCheck=="RasterLayer" | dataCheck=="RasterBrick"){
      xMaxRow <- holdData[which.max(holdData[,"x"]),]
      xMinRow <- holdData[which.min(holdData[,"x"]),]
      yMaxRow <- holdData[which.max(holdData[,"y"]),]
      yMinRow <- holdData[which.min(holdData[,"y"]),]
    }
  }
  
  ##transform the data based on the gdm
  ##part of a loop to prevent memory errors 
  while(istart < rows){
    ##Call the dll function
    data <- holdData[istart:iend,]
    ##adds coordinate rows to data to be transformed
    if((dataCheck=="RasterStack" | dataCheck=="RasterLayer" | dataCheck=="RasterBrick") & geo==TRUE){
      data <- rbind(xMaxRow, xMinRow, yMaxRow, yMinRow, data)
    }
    transformed <- matrix(0,nrow(data),ncol(data))
    z <- .C( "GDM_TransformFromTable",
             as.integer(nrow(data)), 
             as.integer(ncol(data)),
             as.integer(model$gdms[[1]]$geo),
             as.integer(length(model$gdms[[1]]$predictors)), 
             as.integer(model$gdms[[1]]$splines),             
             as.double(model$gdms[[1]]$knots),             
             as.double(model$median.coefs),
             as.matrix(data),
             trandata = as.double(transformed),
             PACKAGE = "gdm")
    
    ## Convert transformed from a vector into a dataframe before returning...
    nRows <- nrow(data)
    nCols <- ncol(data)
    
    ## z$trandata is the transformed data vector created
    myVec <- z$trandata
    pos <- 1
    ##fills out dataframe with transformed values
    for (i in seq(from = 1, to = nCols, by = 1)) {
      tmp <- myVec[seq(from=pos, to=pos+nRows-1)]
      transformed[,i] <- tmp
      pos <- pos + nRows
    }
    
    ##remove the coordinate rows before doing anything else
    if((dataCheck=="RasterStack" | dataCheck=="RasterLayer" | dataCheck=="RasterBrick") & geo==TRUE){
      transformed <- transformed[-c(1:4),]
    }
    
    ##places the transformed values into the readied data frame 
    fullTrans[istart:iend,] <- transformed
    istart <- iend + 1
    iend <- min(istart + (sizeVal-1), rows)
  }
  
  ##if wanted output data as raster, provides maps raster, or output table
  if(dataCheck=="RasterStack" | dataCheck=="RasterLayer" | dataCheck=="RasterBrick"){
    ##maps the transformed data back to the input rasters
    rastLay <- rastDat[[1]]
    rastLay[] <- NA
    outputRasts <- stack()
    for(nn in 1:ncol(fullTrans)){
      #print(nn)
      #nn=1
      holdLay <- rastLay
      holdLay[rastCells] <- fullTrans[,nn]
      #holdLay[rastCells] <- holdData[,nn]
      
      outputRasts <- stack(outputRasts, holdLay)
    }
    ##renames raster layers to be the same as the input
    if(geo){
      names(outputRasts) <- c("xCoord", "yCoord", names(rastDat))
    } else {
      names(outputRasts) <- names(rastDat)
    }
    
    ##get the predictors with non-zero sum of coefficients      
    splineindex <- 1
    predInd <- NULL
    for(i in 1:length(model$gdms[[1]]$predictors)){  
      #i <- 1
      ##only if the sum of the coefficients associated with this predictor is > 0.....
      numsplines <- model$gdms[[1]]$splines[i]
      if(sum(model$median.coefs[splineindex:(splineindex+numsplines-1)])>0){
        predInd <- c(predInd, i)
      }
      splineindex <- splineindex + numsplines
    }
    if(geo){
      predInd <- c(1,2,predInd[-1]+1)
    }
    
    outputRasts <- outputRasts[[predInd]]
    
    ##returns rasters
    return(outputRasts)
  }else{
    if(is.null(rastDat)){
      ##if not raster data, sends back the transformed data
      colnames(fullTrans) <- colnames(data)
      return(fullTrans)
    }else{
      ##returns only the transformed variable data as a table, and the cells with which to map to
      colnames(fullTrans) <- colnames(data)
      return(list(fullTrans, rastCells))
    }
  }
}


############################
## Mistnet ----
############################

#### Calculate variable importance using Olden method, adapted code from "olden" function in NeuralNetTools 
## Works for mistnet with one hidden layer
olden_mistnet<-function (mod_in){
  
  #get names of predictor variables and add latent factors
  x_names<-c(colnames(mod_in$x), paste0("latent", 1:mod_in$sampler$ncol))
  
  #get names of response variables
  y_names<-colnames(mod_in$y)
  
  out<-list()
  out[[1]]<-matrix(nrow=length(x_names), ncol=length(y_names))
  
  # get weights of input to hidden layer
  inp_hid<-mod_in$layers[[1]]$weights
  
  #get weights of hidden layer to output layer 
  hid_out<-mod_in$layers[[2]]$weights
  
  #Calculate sum(input-hidden * hidden-output) to get variable importance.
  #Loop through each output variable
  for (i in 1:length(y_names)){
    out[[1]][,i] <- inp_hid %*% matrix(hid_out[,i])
  }
  
  dimnames(out[[1]])<- list(x_names, y_names )
  
  out[[2]]<-apply(out[[1]], 2, function(x) abs(x)/sum(abs(x))*100 )
  
  out[[3]]<-data.frame (mean=apply(out[[2]], 1, mean), sd=apply(out[[2]], 1, sd))
  
  names(out)<-c("Variable influence", "Relative importance", "Overall relative importance")
  return(out)
}



############################
## RCP----
############################

#### Forward Selection-linear terms----
fwd_step_linear<-function(start_vars,         # names of variables to include in base model (usually from previous step)
                          start_BIC,          # value of BIC from best model in previous step
                          add_vars,           # names of variables to add (one at a time) in this step
                          species,            # names of species to model
                          dist= "Bernoulli",  # distribution for data model (see regimix())
                          nstarts=50,         # number of starts for regimix.multifit
                          form.spp=NULL,      # formula for species artifacts (see regimix())
                          data,               # dataframe that contains all the data to fit regimix model
                          min.nRCP=1,         # minimum number of RCPs to consider
                          max.nRCP,           # maximum number of RCPs to consider
                          mc.cores=1)         # number of cores if parallel processing
  {
  
  #set up results
  BICs<-as.data.frame(setNames(replicate((max.nRCP-min.nRCP+3),numeric(0), simplify = F), c("Var",paste0("RCP", rep(min.nRCP:max.nRCP)),"Start_BIC")))
  
  #loop through adding variables  
  for(j in 1:length(add_vars)){
    add<-add_vars[j]
    temp_form<-as.formula(paste("cbind(",paste(species, collapse=", "),")~ 1+",
                                paste0(paste(start_vars, collapse="+"), "+", paste(add, collapse = "+"))))
    #temp_form<-as.formula(paste("cbind(",paste(species, collapse=", "),")~",
    #                            paste0(paste(start_vars, collapse="+"), paste(add, collapse = "+"))))
    
    #run nRCPs  
    nRCPs_start<- list()
    for( ii in min.nRCP:max.nRCP)
      nRCPs_start[[ii-diff(c(1,min.nRCP))]] <- regimix.multifit(form.RCP=temp_form, form.spp= form.spp, data=data, nRCP=ii, 
                                                                inits="random2", nstart=nstarts, dist=dist, mc.cores=mc.cores)
    
    #get BICs
    RCP1_BICs <- sapply( nRCPs_start, function(x) sapply( x, function(y) y$BIC))
    #Are any RCPs consisting of a small number of sites?  (A posteriori) If so remove.
    RCP1_minPosteriorSites <- cbind( nrow(data), sapply( nRCPs_start[-1], function(y) sapply( y, function(x) min( colSums( x$postProbs)))))
    RCP1_ObviouslyBad <- RCP1_minPosteriorSites < 2
    RCP1_BICs[RCP1_ObviouslyBad] <- NA
    
    
    RCP1_minBICs <- apply( RCP1_BICs, 2, min, na.rm=TRUE)
    BICs[j,1:(ncol(BICs)-1)]<-c(paste0(add), round(RCP1_minBICs,1))
    
  }
  BICs$Start_BIC<-start_BIC
  return(BICs)
}


#### CALCULATE MEAN, SD AND CI OF EXPECTED PROBABILITY OF SPECIES' OCURRENCES IN EACH RCP----
# Mean, SDs and CIs calculate using bootstraps samples
# Option to calculate expected values for each botostrap or summaries for each sampling factor, or across all levels of the data
# currently only accomodates one sampling factor at a time



## Calculates average species prevalence and uncertainty estimates for each RCP using Bayesian bootstraps
## Accomodates single sampling factor
calc_prev<-function(boot_obj,                                              # Regiboot object 
                    mod_obj,                                               # Regimod  object
                    samp_fact=NULL,                                        # Vector of sampling factor names if present
                    calc_level=c("NULL", "bootstrap", "sample_fact", "overall"),   # Level at which to calculate expected prevalence
                    CI=c(0.025,0.975))                                     # Levels at which to calculate confidence intervals
{
  #require(tidyr)
  
  #set up coefficient extraction
  taus<-grepl("tau",dimnames(boot_obj)[[2]])
  alphas<-grepl("alpha",dimnames(boot_obj)[[2]])
  
  if (is.null(samp_fact)){
    
    res_all<-list()
    for(i in 1:dim(boot_obj)[1]){
      
      #extract and reformat coeficients 
      #alpha- OK as is
      temp_alphas<-boot_obj[i,alphas]
      
      #tau
      temp_tau <- boot_obj[i,taus]
      temp_tau <- matrix( temp_tau, nrow=length(mod_obj$names$RCPs)-1)
      tau_all <- rbind( temp_tau, -colSums( temp_tau))
      colnames( tau_all) <- mod_obj$names$spp 
      rownames( tau_all) <- mod_obj$names$RCPs
      
      #calculate values
      lps <- sweep( tau_all, 2, temp_alphas, "+") 
      res_all[[i]]<-as.matrix(round(exp( lps)/ (1+ exp(lps)),3))
    }
    
    overall_temp<-array(unlist(res_all), dim=c( length(mod_obj$names$RCPs),length(mod_obj$names$spp),nrow(boot_obj)))
    overall_res<-list( mean=round(apply(overall_temp, c(1,2), mean),3),
                       sd= round(apply(overall_temp, c(1,2), sd),3),
                       lower= round(apply(overall_temp, c(1,2), function(x) quantile(x, probs=CI[1])),3),
                       upper= round(apply(overall_temp, c(1,2), function(x) quantile(x, probs=CI[2])),3))
    
    dimnames(overall_res[[1]])<-dimnames(overall_res[[2]])<-dimnames(overall_res[[3]])<-dimnames(overall_res[[4]])<-list(mod_obj$names$RCPs, mod_obj$names$spp)
    return (overall_res)
  }
  
  if (! is.null(samp_fact)){
    #extract gammas and set up results frame 
    gammas<-grepl("gamma",dimnames(boot_obj)[[2]])
    res<-rep( list(list()), length(samp_fact)) 
    names(res)<-samp_fact
    
    for(i in 1:dim(boot_obj)[1]){
      print(i)
      
      #extract and reformat coeficients 
      #alpha- OK as is
      temp_alphas<-boot_obj[i,alphas]
      
      #tau
      temp_tau <- boot_obj[i,taus]
      temp_tau <- matrix( temp_tau, nrow=length(mod_obj$names$RCPs)-1)
      tau_all <- rbind( temp_tau, -colSums( temp_tau))
      colnames( tau_all) <- mod_obj$names$spp 
      rownames( tau_all) <- mod_obj$names$RCPs
      
      #gamma
      temp_gamma<-boot_obj[i, gammas]
      temp_gamma<-matrix(temp_gamma, nrow=length(mod_obj$names$spp))
      colnames(temp_gamma)<-mod_obj$names$Wvars
      rownames(temp_gamma)<-mod_obj$names$spp
      
      ## Level 1 of sampling factor (no gamma adjustment needed)
      lps <- sweep( tau_all, 2, temp_alphas, "+") 
      res[[1]][[i]]<-as.matrix(round(exp( lps)/ (1+ exp(lps)),3))
      
      ## other levels of sampling factor
      for(j in 1:length(mod_obj$names$Wvars)){
        lps_temp<-sweep( lps, 2, temp_gamma[,j], "+") 
        res[[j+1]][[i]]<- as.matrix(round(exp( lps_temp)/ (1+ exp(lps_temp)),3))
      }
    }
    
    if(calc_level=="bootstrap"){
      return(res)
    }
    
    
    #Compile list of summaries at the sampling factor level
    if(calc_level=="samp_fact"){
      samp_res<-rep( list(list()), length(samp_fact))
      names(samp_res)<-samp_fact
      
      for(k in 1: length(samp_fact)){
        samp_res[[k]]<-list(mean=round(apply(simplify2array(res[[k]]), c(1,2), mean),3),
                            sd=round(apply(simplify2array(res[[k]]), c(1,2), sd),3),
                            lower=round(apply(simplify2array(res[[k]]), c(1,2), function(x) quantile(x, probs=CI[1])),3),
                            upper=round(apply(simplify2array(res[[k]]), c(1,2), function(x) quantile(x, probs=CI[2])),3))
      }
      return(samp_res)
    }
    
    #compile summaries across each bootstrap for all sampling factors
    if(calc_level=="overall"){
      #extract ith bootstrap values for each sampling factor
      #average species values across sampling factor for each bootstrap
      #perform calculations across averaged bootstrap values
      overall_temp<-list()
      for(i in 1:dim(boot_obj)[1]){
        get_vals<-lapply(res, function(x) x[[i]])
        overall_temp[[i]]<-apply(simplify2array(get_vals), c(1,2), mean)
      }
      overall=list(mean=round(apply(simplify2array(overall_temp), c(1,2), mean),3),
                   sd= round(apply(simplify2array(overall_temp), c(1,2), sd),3),
                   lower= round(apply(simplify2array(overall_temp), c(1,2), function(x) quantile(x, probs=CI[1])),3),
                   upper= round(apply(simplify2array(overall_temp), c(1,2), function(x) quantile(x, probs=CI[2])),3))
      return(overall)
    }
  }
}






############################################################################################
## Tabulate species average and SD of occurrence or predicted probabilities 
## OR average and SD of environmental variables for each group ---
############################################################################################


#match species occurrences (or environment values) with predicted clusters from heirarchical clustering
get_match_vals<-function(site_data,          #dataframe or matrix containing data of species or environment (rows) at sites (cols)
                         pred_cluster_vals,  # vector of values of predicted cluster
                         site_index)         # index values to extract from pred_cluster_vals
{
  pred_match<-data.frame(site_data, clust=as.factor(pred_cluster_vals[site_index]))
  mean_df<-as.data.frame(t(round(aggregate(.~clust, data=pred_match, mean)[,-1],3)))
  sd_df<-as.data.frame(t(round(aggregate(.~clust, data=pred_match, sd)[,-1],3)))
  se_df<-sd_df/sqrt(length(site_index))
  res<-list(mean_df, sd_df, se_df)
  names(res)<-c("mean", "sd", "se")
  return(res)
}

env_match_vals<-function(site_data,          #dataframe or matrix containing data of species or environment (rows) at sites (cols)
                         pred_cluster_vals,  # vector of values of predicted cluster
                         site_index)         # index values to extract from pred_cluster_vals
{
  pred_match<-data.frame(site_data, clust=as.factor(pred_cluster_vals))
  mean_df<-as.data.frame(t(round(aggregate(.~clust, data=pred_match, mean)[,-1],3)))
  sd_df<-as.data.frame(t(round(aggregate(.~clust, data=pred_match, sd)[,-1],3)))
  se_df<-sd_df/sqrt(length(site_index))
  res<-list(mean_df, sd_df, se_df)
  names(res)<-c("mean", "sd", "se")
  return(res)
}


# format table of species means and SDs or SEs ready for compiling a dotplot.
dotplot_sp_tab<-function(mean_df,                     #data frame containing mean values. row=species, cols= groups
                         error_df,                    #data frame containing SD or SE values. row=species, cols= groups
                         nGrp,                        #number of groups
                         species,                     #vector of species names
                         method)                      #name of analysis method
{
  require(tidyr)
  
  temp<-gather(as.data.frame(mean_df), key= Group, value=mean)
  temp$Group<-rep(1:nGrp, each=length(species))
  
  temp_error<-gather(as.data.frame(error_df), key= Group, value=sd)[,2]
  temp$lower<-temp$mean- temp_error
  temp$upper<-temp$mean+ temp_error
  temp$species<-rep(species,nGrp)
  temp$Method<-as.character(method)
  
  return(temp)
}

# format table of environment means and sds ready for compiling a dotplot.
dotplot_env_tab<-function(mean_df,    #data frame containing mean values. row=species, cols= groups
                          error_df,   #data frame containing SD or SE values. row=species, cols= groups
                          nGrp,       #number of groups
                          env,        #vector of environmental variable names
                          method)     #name of analysis method
{
  require(tidyr)
  temp_error<-gather(as.data.frame(error_df), key= Group, value=error)[,2]
  
  temp<-gather(as.data.frame(mean_df), key= Group, value=mean)
  temp$Group<-rep(1:nGrp, each=length(env))
  temp$lower<-temp$mean- temp_error
  temp$upper<-temp$mean+ temp_error
  temp$env<-rep(env,nGrp)
  temp$Method<-as.character(method)
  
  return(temp)
}


###################################################################
## Partial response plots for SAMs and RCPs----
###################################################################

#### partial plots----
#1) generate sequence data to use for plotting (use function: partial_values)
#2) transform plotting data to same scale as used to build models (lapply on partial_values using scale function)
#3) run predictions and plot results (use function: plot_partial)

partial_values<-function(env_vars,       # env_vars= environmental variable names used to build models
                         raw_data,       # raw_data= original raw data dataframe (i.e. unscaled, untransformed)
                         rep_out=100)    # number of values along sequence for plotting
{
  
  #list to contain results
  dat_frames<-list()
  
  #for each variable in env_vars generate sequence from min to max 
  #and paste mean of all other variables
  for(i in 1:length(env_vars)){
    temp=as.data.frame(matrix(nrow=rep_out, ncol = length(env_vars)))
    dat_frames[[i]]<-as.data.frame(cbind(part= seq(from=min(raw_data[,names(raw_data) %in% env_vars[i]]), 
                                                   to=max(raw_data[,names(raw_data) %in% env_vars[i]]),
                                                   length=rep_out),
                                         do.call(rbind,
                                                 replicate(rep_out,colMeans(raw_data[,names(raw_data) %in% env_vars[-i]],na.rm=TRUE)
                                                           , simplify=FALSE))))
    #name variables
    names(dat_frames[[i]])[1]<-env_vars[i]
    dat_frames[[i]]<-dat_frames[[i]][,env_vars]
  }
  #name list element  -added
  names(dat_frames)<-env_vars
  
  dat_frames
}

### predict onto partial,scaled dataframe and plot partial plots. Point predictions only atm!
plot_partial<-function(env_vars,             # names of environmental variables used in model
                       partial_space_out,    # scaled values for prediction (i.e. output of step 2)
                       partial_vals_out,     # unscaled values for plotting (i.e. output of partial_values)
                       model=c("sam", "rcp"),# predict using sam or rcp
                       object,               # SAM or RCP model to use for predictions
                       mfrow=c(2,2))         # layout for plotting
                       #file_name=NULL,       # filename for saving pdf of plot
                       #width=8, height=8)    # size of pdf 
{
  #pdf(file= paste0(file_name, "PPlots.pdf"), height=height, width=width)
  #palette(cols)
  par(mfrow=mfrow, mar=c(5,4,2,2))
  for(i in 1:length(partial_vals_out)){
    temp<-as.data.frame(partial_space_out[[i]])
    
    if(model=="sam"){
    pred<-predict(object=object, new.obs=temp)
    matplot(x=as.vector(partial_vals_out[[i]][,names(partial_vals_out[[i]]) %in% env_vars[i]]), 
            y= pred$fit, type='l', 
            xlab=env_vars[i], ylab="Probability of Occurrence", ylim=c(0,1), lwd=3)
    
    legend(x="topright", legend=dimnames(pred$fit)[[2]], col=1:length(dimnames(pred$fit)[[2]]), lty=1, cex=0.9, bty="n")
    }
  
   if(model=="rcp"){
     pred<-predict(object=object, newdata=temp)
     matplot(x=as.vector(partial_vals_out[[i]][,names(partial_vals_out[[i]]) %in% env_vars[i]]), 
             y= pred, type='l', 
             xlab=env_vars[i], ylab="Probability of Occurrence", ylim=c(0,1), lwd=3)
     legend(x="topright", legend=dimnames(pred)[[2]], col=1:length(dimnames(pred)[[2]]), lty=1, cex=0.9, bty="n")
   }
}
  

}


