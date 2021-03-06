#/*
#**
#* BEGIN_COPYRIGHT
#*
#* This file is part of SciDB.
#* Copyright (C) 2008-2013 SciDB, Inc.
#*
#* SciDB is free software: you can redistribute it and/or modify
#* it under the terms of the AFFERO GNU General Public License as published by
#* the Free Software Foundation.
#*
#* SciDB is distributed "AS-IS" AND WITHOUT ANY WARRANTY OF ANY KIND,
#* INCLUDING ANY IMPLIED WARRANTY OF MERCHANTABILITY,
#* NON-INFRINGEMENT, OR FITNESS FOR A PARTICULAR PURPOSE. See
#* the AFFERO GNU General Public License for the complete license terms.
#*
#* You should have received a copy of the AFFERO GNU General Public License
#* along with SciDB.  If not, see <http://www.gnu.org/licenses/agpl-3.0.html>
#*
#* END_COPYRIGHT
#*/

# This file contains functions that map R indexing operations to SciDB queries.
# Examples include subarray and cross_join wrappers.  They are a bit
# complicated in order to support empty-able and NID arrays.

# A utility function that returns TRUE if entries in the numeric vector j
# are sequential and in increasing order.
checkseq = function(j)
{
  if(!is.numeric(j)) return(FALSE)
  !any(diff(j)!=1)
}

# Returns a function that evaluates to a list of bounds
between = function(a,b)
{
  if(missing(b))
  {
    if(length(a)==2)
    {
      b = a[[2]]
      a = a[[1]]
    } else stop("between requires two arguments or a single argument with two elements")
  }
  function() list(a,b)
}


# dimfilter: The workhorse array subsetting function
# INPUT
# x: A scidb object
# i: a list of index expressions
# eval: (logical) if TRUE, return a new SciDB array, otherwise just a promise
# OUTPUT
# a scidb object
#
# dimfilter distinguishes between four kinds of indexing operations:
# 'si' sequential numeric index range, for example c(1,2,3,4,5)
# 'bi' special between index range, that is a function or a list
#      that returns upper/lower limits
# 'ui' not specified range (everything, by R convention)
# 'ci' other, for example c(3,1,2,5) or c(1,1)
#
dimfilter = function(x, i, eval)
{
# Partition the indices into class:
# Identify sequential, numeric indices
  si = sapply(i, scidb:::checkseq)
# Identify explicit between-type indices (functions, lists)
  bi = sapply(i, function(x) inherits(x,"function"))
# Unspecified range
  ui = sapply(i,is.null)
# Identify everything else
  ci = !(si | bi | ui)

  if(length(x@attribute)<1) x@attribute=x@attributes[1]
  r = lapply(1:length(bi), function(j)
    {
      if(bi[j])
      {
# Just use the provided between-style range
        unlist(i[j][[1]]())
      }
      else if(si[j])
      {
# sequential numeric or lookup-type range
        c(min(i[j][[1]]),max(i[j][[1]]))
      }
      else
       {
# Unspecified range or special index (ci case), which we handle later.
         c(x@D$start[j],x@D$start[j] + x@D$length[j] - 1)
       }
    })
  r = unlist(lapply(r,function(x)sprintf("%.0f",x)))
  ro = r[seq(from=1,to=length(r),by=2)]
  re = r[seq(from=2,to=length(r),by=2)]
  r = paste(c(ro,re),collapse=",")
  q = sprintf("between(%s,%s)",x@name,r)

  if(any(ci)) 
  {
    stop("Not yet supported")
  }
  q = sprintf("subarray(%s,%s)",q,r)
# Return a new scidb array reference
# Unfortunately not the same as:
#  sub = paste(rep('null',length(r)),collapse=",")
#  q = sprintf("subarray(%s,%s)",q,r)
  .scidbeval(q,eval=eval,gc=TRUE,attribute=x@attribute,`data.frame`=FALSE,depend=x)
}


special_index = function(x, query, i, idx, eval)
{
}


# Materialize the single-attribute scidb array x as an R array.
materialize = function(x, drop=FALSE)
{
  type = names(.scidbtypes[.scidbtypes==x@type])
  if(length(type)<1) stop("Unsupported data type. Try using the iquery function instead.")
  tval = vector(mode=type,length=1)

# Set origin to zero and project.
  l1 = length(dim(x))
  lb = paste(rep("null",l1),collapse=",")
  ub = paste(rep("null",l1),collapse=",")
  query = sprintf("subarray(project(%s,%s),%s,%s)",x@name,x@attribute,lb,ub)

# Unpack
  query = sprintf("unpack(%s,%s)",query,"__row")

  i = paste(rep("int64",length(x@dim)),collapse=",")
#  nl = x@nullable[x@attribute==x@attributes][[1]]
  nl = TRUE
  N = ifelse(nl,"NULL","")

  savestring = sprintf("(%s,%s %s)",i,x@type,N)

  sessionid = tryCatch(
                scidbquery(query, save=savestring, async=FALSE, release=0),
                error = function(e) {stop(e)})
# Release the session on exit
  on.exit( GET("/release_session",list(id=sessionid)) ,add=TRUE)
  n = 0

  r = URI("/read_bytes",list(id=sessionid,n=n))
  BUF = getBinaryURL(r, .opts=list('ssl.verifypeer'=0))

  ndim = as.integer(length(x@D$name))
  type = eval(parse(text=paste(names(.scidbtypes[.scidbtypes==x@type]),"()")))
  len  = as.integer(.typelen[names(.scidbtypes[.scidbtypes==x@type])])
  len  = len + nl # Type length

  nelem = length(BUF) / (ndim*8 + len)
  stopifnot(nelem==as.integer(nelem))
  A = tryCatch(
    {
      .Call("scidbparse",BUF,ndim,as.integer(nelem),type,N)
    },
    error = function(e){stop(e)})

  p = prod(x@D$length)

# Check for sparse matrix case
  if(ndim==2 && nelem<p)
  {
    return(sparseMatrix(i=A[[2]][,1]+1,j=A[[2]][,2]+1,x=A[[1]],dims=x@D$length))
  } else if(nelem<p)
  {
# Don't know how to represent this in R!
    names(A)=c("values","coordinates")
    return(A)
  }
  if(ndim==2)
    return(matrix(data=A[[1]], nrow=x@D$length[[1]],byrow=TRUE))
  aperm(array(data=A[[1]], dim=x@D$length, dimnames=x@D$name),
        perm=seq(from=length(x@D$length),to=1,by=-1))
}
