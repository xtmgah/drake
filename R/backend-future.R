backend_future <- function(config) {
  assert_pkg("future")
  queue <- new_priority_queue(config = config)
  workers <- initialize_workers(config)
  # While any targets are queued or running...
  i <- 1
  ft_config <- ft_config(config)
  while (work_remains(queue = queue, workers = workers, config = config)) {
    for (id in seq_along(workers)) {
      if (is_idle(workers[[id]])) {
        i <- 1
        # Also calls decrease-key on the queue.
        workers[[id]] <- conclude_worker(
          worker = workers[[id]],
          config = config,
          queue = queue
        )
        # Pop the head target only if its priority is 0
        next_target <- queue$pop0()
        if (!length(next_target)) {
          # It's hard to make this line run in a small test workflow
          # suitable enough for unit testing, but
          # I did artificially stall targets and verified that this line
          # is reached in the future::multisession backend as expected.
          next # nocov
        }
        running <- running_targets(workers = workers, config = config)
        protect <- c(running, queue$list())
        if (identical(config$layout[[next_target]]$hpc, FALSE)) {
          future_local_build(next_target, config, queue, protect)
        } else {
          workers[[id]] <- new_worker(
            id,
            next_target,
            config,
            ft_config,
            protect
          )
        }
      }
    }
    Sys.sleep(config$sleep(max(0L, i)))
    i <- i + 1
  }
}

#' @title Task passed to individual futures in the `"future"` backend
#' @description For internal use only. Only exported to make available
#' to futures.
#' @keywords internal
#' @export
#' @return Either the target value or a list of build results.
#' @param target Name of the target.
#' @param meta A list of metadata.
#' @param config A [drake_config()] list.
#' @param protect Names of targets that still need their
#' dependencies available in memory.
future_build <- function(target, meta, config, layout, protect) {
  config$layout <- list()
  config$layout[[target]] <- layout
  if (identical(config$caching, "worker")) {
    manage_memory(targets = target, config = config, downstream = protect)
  }
  do_prework(config = config, verbose_packages = FALSE)
  build <- build_target(target = target, meta = meta, config = config)
  if (identical(config$caching, "master")) {
    build$checksum <- mc_get_outfile_checksum(target, config)
    return(build)
  }
  conclude_build(build = build, config = config)
  list(target = target, checksum = mc_get_checksum(target, config))
}

future_local_build <- function(target, config, queue, protect) {
  log_msg("local target", target, config = config)
  loop_build(target, config, downstream = protect)
  decrease_revdep_keys(queue, target, config)
}

new_worker <- function(id, target, config, ft_config, protect) {
  meta <- drake_meta_(target = target, config = config)
  if (!should_build_target(target, meta, config)) {
    log_msg("skip", target, config = config)
    return(empty_worker(target = target))
  }
  if (identical(config$caching, "master")) {
    manage_memory(targets = target, config = config, downstream = protect)
  }
  DRAKE_GLOBALS__ <- NULL # Fixes warning about undefined globals.
  # Avoid potential name conflicts with other globals.
  # When we solve #296, need for such a clumsy workaround
  # should go away.
  layout <- config$layout[[target]]
  globals <- future_globals(
    target = target,
    meta = meta,
    config = ft_config,
    layout = layout,
    protect = protect
  )
  announce_build(target = target, meta = meta, config = config)
  structure(
    future::future(
      expr = drake::future_build(
        target = DRAKE_GLOBALS__$target,
        meta = DRAKE_GLOBALS__$meta,
        config = DRAKE_GLOBALS__$config,
        layout = DRAKE_GLOBALS__$layout,
        protect = DRAKE_GLOBALS__$protect
      ),
      globals = globals,
      label = target,
      resources = as.list(layout$resources)
    ),
    target = target
  )
}

future_globals <- function(target, meta, config, layout, protect) {
  globals <- list(
    DRAKE_GLOBALS__ = list(
      target = target,
      meta = meta,
      config = config,
      layout = layout,
      protect = protect
    )
  )
  if (identical(config$envir, globalenv())) {
    # nocov start
    # Unit tests should not modify global env
    if (exists("DRAKE_GLOBALS__", config$envir)) {
      warning(
        "Do not define an object named `DRAKE_GLOBALS__` ",
        "in the global environment",
        call. = FALSE
      )
    }
    globals <- c(globals, as.list(config$envir, all.names = TRUE))
    # nocov end
  }
  globals
}

empty_worker <- function(target) {
  structure(NA_character_, target = target)
}

is_empty_worker <- function(worker) {
  !inherits(worker, "Future")
}

concluded_worker <- function() {
  empty_worker(target = NULL)
}

is_concluded_worker <- function(worker) {
  is.null(attr(worker, "target"))
}

# Need to check if the worker quit in error early somehow.
# Maybe the job scheduler failed.
# This should be the responsibility of the `future` package
# or something lower level.
is_idle <- function(worker) {
  is_empty_worker(worker) ||
    is_concluded_worker(worker) ||
    future::resolved(worker)
}

work_remains <- function(queue, workers, config) {
  !queue$empty() ||
    !all_concluded(workers = workers, config = config)
}

all_concluded <- function(workers, config) {
  for (worker in workers) {
    if (!is_concluded_worker(worker)) {
      return(FALSE)
    }
  }
  TRUE
}

running_targets <- function(workers, config) {
  out <- lapply(
    X = workers,
    FUN = function(worker) {
      if (is_idle(worker)) {
        NULL
      } else {
        # It's hard to make this line run in a small test workflow
        # suitable enough for unit testing, but
        # I did artificially stall targets and verified that this line
        # is reached in the future::multisession backend as expected.
        attr(worker, "target") # nocov
      }
    }
  )
  unlist(out)
}

initialize_workers <- function(config) {
  out <- list()
  for (i in seq_len(config$jobs))
    out[[i]] <- empty_worker(target = NA_character_)
  out
}

ft_config <- function(config) {
  discard <- c(
    "imports",
    "layout",
    "plan",
    "graph",
    "schedule",
    "targets",
    "trigger"
  )
  for (x in discard) {
    config[[x]] <- NULL
  }
  config$cache$flush_cache()
  config
}

ft_decrease_revdep_keys <- function(worker, config, queue) {
  target <- attr(worker, "target")
  if (!length(target) || safe_is_na(target) || !is.character(target)) {
    return()
  }
  decrease_revdep_keys(queue, target, config)
}

conclude_worker <- function(worker, config, queue) {
  ft_decrease_revdep_keys(
    worker = worker,
    queue = queue,
    config = config
  )
  out <- concluded_worker()
  if (is_empty_worker(worker)) {
    return(out)
  }
  build <- resolve_worker_value(worker = worker, config = config)
  if (identical(config$caching, "worker")) {
    mc_wait_checksum(
      target = build$target,
      checksum = build$checksum,
      config = config
    )
    return(out)
  }
  mc_wait_outfile_checksum(
    target = build$target,
    checksum = build$checksum,
    config = config
  )
  conclude_build(build = build, config = config)
  out
}

# Also caches error information if available.
# I know, it has a return value AND a side effect,
# but it's hard to think of another clean way
# to handle crashes.
resolve_worker_value <- function(worker, config) {
  tryCatch(
    # Check if the worker crashed.
    future::value(worker),
    error = function(e) {
      e$message <- paste0(
        "Worker terminated unexpectedly before the target could complete. ",
        "Is something wrong with your system or job scheduler?"
      )
      meta <- list(error = e)
      if (config$caching == "worker") {
        # Need to store the error if the worker crashed.
        handle_build_exceptions(
          target = attr(worker, "target"),
          meta = meta,
          config = config
        )
      }
      # For `caching = "master"`, we need to conclude the build
      # and store the value and metadata.
      list(
        target = attr(worker, "target"),
        value = e,
        meta = meta
      )
    }
  )
}
