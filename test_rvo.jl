using PyCall
println("PyCall python: ", PyCall.python)
rvo = pyimport("rvo2")
println("rvo2 imported: ", rvo)
sim = rvo.PyRVOSimulator(1/60, 1.5, 5, 1.5, 2.0, 0.4, 2.0)
println("sim created: ", sim)
println("RVO2_OK")
