# basic autocompletion support (used for the Python REPL)
py_completer <- function(line) {
  
  # helper function for constructing a regular expression pattern from token
  pattern <- function(token) { paste("^\\Q", token, "\\E", sep = "") }
  
  # helper function for filtering a completion set
  # TODO: do we want to allow for e.g. RStudio-style subsequence matching?
  filter <- function(completions, token) {
    if (nzchar(token))
      grep(pattern(token), completions, perl = TRUE, value = TRUE)
    else
      completions
  }
  
  # import with 'convert = FALSE' to minimize potential for unintended
  # coercion between Python and R (only do it explicitly)
  os <- import("os", convert = FALSE)
  sys <- import("sys", convert = FALSE)
  main <- import_main(convert = FALSE)
  keyword <- import("keyword", convert = FALSE)
  builtins <- import_builtins(convert = FALSE)
  
  # extract line
  trimmed <- sub("^\\s*", "", line)
  
  # check to see if we're attempting to import a module
  if (grepl("^import\\s+[\\w_]*", trimmed, perl = TRUE)) {
    
    modules <- py_list_modules()
    
    # figure out what the user has typed so far
    parts <- strsplit(trimmed, "\\s+")[[1]]
    token <- if (length(parts) == 1) "" else parts[[2]]
    
    # find the last dot in the token (for cases where the user is
    # importing a submodule)
    dots <- gregexpr(".", token, fixed = TRUE)[[1]]
    if (identical(c(dots), -1L)) {
      toplevel <- grep(".", modules, fixed = TRUE, invert = TRUE, value = TRUE)
      completions <- filter(toplevel, token)
      return(sort(completions))
    }
    
    # we had dots; list all sub-modules of that module (since
    # we're now scoped to sub-modules it doesn't hurt to
    # display potentially more than just one layer)
    completions <- filter(modules, token)
    return(sort(completions))
  }
  
  # otherwise, just try to grab completions in the main module + builtins
  spaces <- gregexpr("[[:space:]]", line)[[1]]
  last <- tail(spaces, n = 1)
  token <- substring(line, last + 1)
  
  # check for completion of dictionary keys, e.g.
  #
  #   foo["ab
  #
  re_lookup <- "([\\w_.]+)\\s*\\[\\s*['\"]([\\w_.]*)"
  matches <- regmatches(token, regexec(re_lookup, token, perl = TRUE))[[1]]
  if (length(matches) == 3) {
    
    lhs <- matches[[2]]
    rhs <- matches[[3]]
    
    object <- tryCatch(py_eval(lhs, convert = FALSE), error = identity)
    if (inherits(object, "error"))
      return(character())
    
    method <- py_get_attr(object, "keys", silent = TRUE)
    if (!inherits(method, "python.builtin.object"))
      return(character())
    
    keys <- py_to_r(method)
    candidates <- py_to_r(keys())
    
    completions <- filter(candidates, rhs)
    return(sort(completions))
  }
  
  # check for completion of file names within strings, e.g.
  #
  #   read("~/foo.R")
  #
  # note that Python APIs don't perform tilde expansion, so the onus
  # is on us to do that for the user
  context <- py_completion_context(token)
  if (context$state %in% c("'", "\"")) {
    index <- context$index
    
    # extract the portion of the filepath provided by the user thus far
    path <- path.expand(substring(token, index + 1))
    
    # find the index of the last slash -- everything following is
    # the completion token; everything before is the directory to
    # search for completions in
    indices <- gregexpr("/", path, fixed = TRUE)[[1]]
    if (!identical(c(indices), -1L)) {
      lhs <- substring(path, 1, tail(indices, n = 1) - 1)
      rhs <- substring(path, tail(indices, n = 1) + 1)
    } else {
      lhs <- ""
      rhs <- path
    }
    
    files <- if (nzchar(lhs)) {
      file.path(lhs, list.files(lhs))
    } else {
      list.files(py_to_r(os$getcwd()))
    }
    
    completions <- filter(files, rhs)
    return(sort(completions))
    
  }
  
  # now, assume 'default' completion context (items from main module,
  # or attributes of a Python object)
  dots <- gregexpr(".", token, fixed = TRUE)[[1]]
  if (identical(c(dots), -1L)) {
    # no dots; just try to complete objects from the main module
    items <- c(names(main), names(builtins), py_to_r(keyword$kwlist))
    completions <- filter(items, token)
    return(sort(completions))
  }
  
  # we had dots; try to evaluate the left-hand side of the dots
  # and then filter on the attributes of the object (if any)
  last <- tail(dots, n = 1)
  lhs <- substring(token, 1, last - 1)
  rhs <- substring(token, last + 1)
  
  # try evaluating the left-hand side
  object <- tryCatch(py_eval(lhs, convert = FALSE), error = identity)
  if (inherits(object, "error"))
    return(character())
  
  # attempt to get completions
  items <- tryCatch(py_list_attributes(object), error = identity)
  if (inherits(items, "error"))
    return(character())
  completions <- filter(items, rhs)
  
  # re-attach the lhs of the completion string
  completions <- paste(lhs, completions, sep = '.')
  
  # sort and we're done!
  return(sort(completions))
}

# list available modules (including submodules). note that this is an expensive
# task as it requires crawling through the filesystem for Python packages
# on the sys.path, so results need to be cached
py_list_modules <- function() {
  
  # use cached modules if available
  if (!is.null(.globals$modules))
    return(.globals$modules)
  
  # first, grab builtin modules
  sys <- import("sys")
  builtins <- as.character(sys$builtin_module_names)
  
  # now, search for other modules within the common paths
  paths <- sys$path
  
  # helper function for constructing a regular expression pattern from token
  pattern <- function(token) { paste("^\\Q", token, "\\E", sep = "") }
  
  # remove paths that are a subdirectory of another path in the set (so we
  # don't recursively crawl directories we've already visited)
  prefixes <- Reduce(`+`, lapply(paths, function(path) {
    grepl(pattern(path), paths, perl = TRUE)
  }))
  paths <- paths[prefixes == 1]
  
  # now, recursively search for __init__.py -- each directory that contains
  # such a file can be considered as a module
  discovered <- new.env(parent = emptyenv())
  list_submodules <- function(root, child) {
    
    # bail if no '__init__.py'
    if (!file.exists(file.path(child, "__init__.py")))
      return()
    
    # contains an __init__.py; it's a module
    name <- gsub("/", ".", substring(child, nchar(root) + 2), fixed = TRUE)
    discovered[[name]] <<- TRUE
    
    # now search sub-directories for modules too
    children <- list.dirs(child, recursive = FALSE)
    lapply(children, function(child) {
      list_submodules(root, child)
    })
    
  }
  
  for (root in paths) {
    children <- list.dirs(root, recursive = FALSE)
    lapply(children, function(child) {
      list_submodules(root, child)
    })
  }
  
  modules <- ls(envir = discovered)
  
  # collect all our discoveries together
  all <- unique(sort(c(builtins, modules)))
  
  # cache for quick lookup
  .globals$modules <- all
  
  all
}

py_completion_context <- function(line) {
  
  # states we care about for our completion context
  STATE_TOPLEVEL <- "<top>"    
  STATE_SQUOTE   <- "'"
  STATE_DQUOTE   <- "\""
  
  state <- new_stack()
  state$push(list(index = 0, state = STATE_TOPLEVEL))
  
  # would love to use Python's own tokenizer here but it doesn't handle
  # incomplete strings (it returns an error instead) so we implement our
  # own ad-hoc tokenizer with just enough to get completion context we need
  
  # iterate through tokens
  i <- 0; n <- nchar(line)
  while (i < n) {
    
    # move to next character
    i <- i + 1; c <- substring(line, i, i)
    
    # on backslash, skip to next character
    if (c == "\\") {
      i <- i + 1
      next
    }
    
    # grab current state and figure out next action
    current <- state$peek()$state
    if (current == STATE_TOPLEVEL) {
      
      if (c == "'") {
        state$push(list(index = i, state = STATE_SQUOTE))
        next
      }
      
      if (c == "\"") {
        state$push(list(index = i, state = STATE_DQUOTE))
        next
      }
      
    }
    
    if (current == STATE_SQUOTE) {
      
      if (c == "'") {
        state$pop()
        next
      }
      
    }
    
    if (current == STATE_DQUOTE) {
      
      if (c == "\"") {
        state$pop()
        next
      }
      
    }
    
  }
  
  state$peek()
  
}
