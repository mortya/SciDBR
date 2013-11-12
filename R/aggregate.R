# x:   A scidb, scidbdf object
# by:  A character vector of dimension and or attribute names of x, or,
#      a scidb or scidbdf object that will be cross_joined to x and then
#      grouped by attribues of by.
# FUN: A SciDB aggregation expresion
`aggregate_scidb` = function(x,by,FUN,eval)
{
  b = `by`
  if(is.list(b)) b = b[[1]]
  if(class(b) %in% c("scidb","scidbdf"))
  {
# We are grouping by attributes in another SciDB array `by`. We assume that
# x and by have conformable dimensions to join along.
    j = intersect(x@D$name, b@D$name)
    X = merge(x,b,by=list(j,j),eval=FALSE)
    n = by@attributes
    by = list(n)
  }

  if(missing(`eval`))
  {
    nf   = sys.nframe() - 2  # Note! this is a method and is on a deeper stack.
    `eval` = !called_from_scidb(nf)
  }
# A bug in SciDB 13.6 unpack prevents us from using eval=FALSE for now.
  if(!eval && !compare_versions(options("scidb.version")[[1]],13.9)) stop("eval=FALSE not supported by aggregate due to a bug in SciDB <= 13.6")

  b = `by`
  new_dim_name = make.names_(c(unlist(b),"row"))
  new_dim_name = new_dim_name[length(new_dim_name)]
  if(!all(b %in% c(x@attributes, x@D$name))) stop("Invalid attribute or dimension name in by")
  a = x@attributes %in% b
  query = x@name
# Handle group by attributes with redimension. We don't use a redimension
# aggregate, however, because some of the other group by variables may
# already be dimensions.
  if(any(a))
  {
# First, we check to see if any of the attributes are not int64. In such cases,
# we use index_lookup to create a factorized version of the attribute to group
# by in place of the original specified attribute. This creates a new virtual
# array x with additional attributes.
    types = x@attributes[a]
    nonint = x@types != "int64" & a
    if(any(nonint))
    {
# Use index_lookup to factorize non-integer indices, creating new enumerated
# attributes to sort by. It's probably not a great idea to have too many.
      idx = which(nonint)
      oldatr = x@attributes
      for(j in idx)
      {
        atr     = oldatr[j]
# Adjust the FUN expression to include the original attribute
        FUN = sprintf("%s, min(%s) as %s", FUN, atr, atr)
# Factorize atr
        x       = index_lookup(x,unique(sort(project(x,atr)),sort=FALSE),atr)
# Name the new attribute and sort by it instead of originally specified one.
        newname = paste(atr,"index",sep="_")
        newname = make.unique_(oldatr,newname)
        b[which(b==atr)] = newname
      }
# XXX XXX length(idx) > 1???
    }

# Reset in case things changed above
    a = x@attributes %in% b
    n = x@attributes[a]
# XXX What about chunk sizes? NULLs? Ugh. Also insert reasonable upper bound instead of *? XXX Take care of all these issues...
    redim = paste(paste(n,"=0:*,1000,0",sep=""), collapse=",")
    D = paste(build_dim_schema(x,FALSE),redim,sep=",")
    A = x
    A@attributes = x@attributes[!a]
    A@nullable   = x@nullable[!a]
    A@types      = x@types[!a]
    S = build_attr_schema(A)
    D = sprintf("[%s]",D)
    query = sprintf("redimension(substitute(%s,build(<_i_:int64>[_j_=0:0,1,0],-1)),%s%s)",x@name,S,D)
  }
  along = paste(b,collapse=",")

# We use unpack to always return a data frame (a 1D scidb array). As of
# SciDB 13.6 unpack has a bug that prevents it from working often. Saving to a
# temporary array first seems to be a workaround for this problem. This sucks.
  query = sprintf("aggregate(%s, %s, %s)",query, FUN, along)
  if(!compare_versions(options("scidb.version")[[1]],13.9))
  {
    temp = scidbeval(query,TRUE)
    query = sprintf("unpack(%s,%s)",temp@name,new_dim_name)
  } else
  {
    query = sprintf("unpack(%s,%s)",query,new_dim_name)
  }
  scidbeval(query,eval)
}