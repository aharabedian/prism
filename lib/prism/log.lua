-- prism.log: log(fmt, ...) writes one timestamped line to the terminal.
return function(fmt, ...)
  io.write(os.date("[%H:%M:%S] "), string.format(fmt, ...), "\n")
end
