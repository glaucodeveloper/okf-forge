# O repositório original foi publicado com um caminho Windows absoluto.
# Neste ambiente Linux, usamos a cópia local de desenvolvimento do framework.
switch("path", "/home/icarogdo/dev/plasticglauco/src")
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
