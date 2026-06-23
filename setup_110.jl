ENV["PYTHON"] = raw"C:\Users\chahj\anaconda3\envs\lego_rvo2\python.exe"
using Pkg
println("Julia version: ", VERSION)
Pkg.instantiate()
Pkg.build("PyCall")
println("SETUP_110_DONE")
