# 
# implementation greatly inspired from: https://github.com/geodynamics/seismic_cpml/blob/master

# # Credits 
# Author: Pawan Bharadwaj 
#         (bharadwaj.pawan@gmail.com)
# 
# * original code in FORTRAN90: March 2013
# * modified: 11 Sept 2013
# * major update: 25 July 2014
# * code optimization with help from Jan Thorbecke: Dec 2015
# * rewritten in Julia: June 2017
# * added parrallelization over supersources in Julia: July 2017
# * efficient parrallelization using distributed arrays: Sept 2017
# * optimized memory allocation: Oct 2017

# 
function AA(use_gpu,n)
	# ParallelStencil.@reset_parallel_stencil()
	# use_gpu ? 
	# @init_parallel_stencil(CUDA, Float64, 2) :
	@init_parallel_stencil(Threads, Float64, 2)
end
"""
2-D acoustic forward modeling using a finite-difference simulation of the acoustic wave-equation.
"""
struct FdtdAcou end

"""
2-D ViscoAcoustic forward modeling using a finite-difference simulation of the acoustic wave-equation.
"""
struct FdtdAcouVisco  end

"""
2-D Linearized forward modeling using a finite-difference simulation of the acoustic wave-equation.
"""
struct FdtdAcouBorn  end

# union of old stuff without using ParallelStencils (should eventually remove this)
FdtdOld=Union{FdtdAcou,FdtdAcouVisco,FdtdAcouBorn}

global const npml = 50
global const nlayer_rand = 0

include("types.jl")
include("attenuation.jl")

# 
#As forward modeling method, the 
#finite-difference method is employed. 
#It uses a discrete version of the two-dimensional isotropic acoustic wave equation.
#
#```math
#\pp[\tzero] - \pp[\tmo] = \dt \mB \left({\partial_x\vx}[\tmh]
# + \partial_z \vz[\tmh]  + \dt\sum_{0}^{\tmo}\sfo\right)
# ```
# ```math
#\pp[\tpo] - \pp[\tzero] = \dt \mB \left(\partial_x \vx[\tph]
# + {\partial_z \vz}[\tph]  + \dt\sum_{0}^{\tzero}\sfo\right)
# ```

#attenuation related
#Rmemory::StackedArray2DVector{Array{Float64,3}} # memory variable for attenuation, see Carcione et al (1988), GJ
#Rmemoryp::StackedArray2DVector{Array{Float64,3}} # at previous time step

"""
```julia
pa = SeisForwExpt(attrib_mod; ageom, srcwav, medium, tgrid);
```168G
Method to create an instance of `SeisForwExpt`. 
The output of this method can be used as an input to the in-place method `update!`, to actually perform a
finite-difference modeling.

# Keyword Arguments

* `attrib_mod` : attribute to choose the type of modeling. Choose from 
  * `=FdtdAcou()` for full wavefield modeling  (finite-difference simulation of the acoustic wave-equation)
  * `=FdtdAcouBorn()` for Born modeling 
* `model::Medium` : medium parameters 
* `tgrid` : modeling time grid, maximum time in `tgrid`should be greater than or equal to maximum source time, same sampling interval as in `srcwav`
* `ageom` :  acquisition 
* `srcwav` : source wavelets  

# Optional Keyword Arguments 

* `sflags=2` : source related flags 
  * `=0` inactive sources
  * `=1` sources with injection rate
  * `=2` volume injection sources
  * `=3` sources input after time reversal (use only during backpropagation)
* `rflags=1` : receiver related flags 
  * `=0` receivers do not record (or) inactive receivers
  * `=1` receivers are active only for the second propagating wavefield
* `rfields=[:P]` : multi-component receiver flag. Choose `Vector{Symbol}`
  * `=[:P]` record pressure 
  * `=[:vx]` record horizontal component of particle velocity  
  * `=[:vz]` record vertical component of particle velocity  
  * `=[:P, :vx]` record both pressure and velocity 
* `tsnaps` : store snaps at these modeling times (defaults to half time)
  * `=[0.1,0.2,0.3]` record at these instances of tgrid
* `snaps_flag::Bool=false` : return snapshots or not
* `verbose::Bool=false` : verbose flag
"""
SeisForwExpt(attrib_mod::Union{FdtdAcou,FdtdAcouBorn,FdtdAcouVisco},args1...;args2...)=PFdtd(attrib_mod,args1...;args2...)


"""
Primary method to generate Expt variable when FdtdAcou() and FdtdAcouBorn() are used.

# Some internal arguments
* `jobname::String` : name
* `npw::Int64=1` : number of independently propagating wavefields in `medium`
* `backprop_flag::Bool=Int64` : save final state variables and the boundary conditions for later use
  * `=1` save boundary and final values in `boundary` 
  * `=-1` use stored values in `boundary` for back propagation
* `gmodel_flag=false` : flag that is used to output gradient; there should be atleast two propagating wavefields in order to do so: 1) forward wavefield and 2) adjoint wavefield
* `illum_flag::Bool=false` : flag to output wavefield energy or source illumination; it can be used as preconditioner during inversion
* `abs_trbl::Vector{Symbol}=[:zmin, :zmax, :xmax, :xmin]` : use absorbing PML boundary conditions or not
  * `=[:zmin, :zmax]` apply PML conditions only at the top and bottom of the medium 
  * `=[:zmax, :xmax, :xmin]` top is reflecting
"""
function PFdtd(attrib_mod;
	jobname::Symbol=:forward_propagation,
	npw::Int64=1, 
	medium::Medium=nothing,
	abs_trbl::Vector{Symbol}=[:zmin, :zmax, :xmax, :xmin],
	tgrid::StepRangeLen=nothing,
	ageom::Union{AGeom,Vector{AGeom}}=nothing,
	srcwav::Union{SrcWav,Vector{SrcWav}}=nothing,
	sflags::Union{Int,Vector{Int}}=fill(2,npw), 
	rflags::Union{Int,Vector{Int}}=fill(1,npw),
	rfields::Vector{Symbol}=[:p], 
	backprop_flag::Int64=0,  
	gmodel_flag::Bool=false,
	illum_flag::Bool=false,
	tsnaps::Vector{Float64}=fill(0.5*(tgrid[end]+tgrid[1]),1),
	snaps_flag::Bool=false,
	verbose::Bool=false,
	nworker=nothing)

	# convert to vectors 
	if(typeof(ageom)==AGeom); ageom=[ageom]; end
	if(typeof(srcwav)==SrcWav); srcwav=[srcwav]; end
	if(typeof(sflags)==Int); sflags=[sflags]; end
	if(typeof(rflags)==Int); rflags=[rflags]; end

	# alias
	tgridmod=tgrid

	#println("********PML Removed*************")
	#abs_trbl=[:null]

	# check sizes and errors based on input
	#(length(TDout) ≠ length(findn(rflags))) && error("TDout dimension")
	(length(ageom) ≠ npw) && error("ageom dimension")
	(length(srcwav) ≠ npw) && error("srcwav dimension")
	(length(sflags) ≠ npw) && error("sflags dimension")
	(length(rflags) ≠ npw) && error("rflags dimension")
	(maximum(tgridmod) < maximum(srcwav[1][1].grid)) && error("modeling time is less than source time")
	#(any([getfield(TDout[ip],:tgrid).δx < tgridmod.δx for ip=1:length(TDout)])) && error("output time grid sampling finer than modeling")
	#any([maximum(getfield(TDout[ip],:tgrid).x) > maximum(tgridmod) for ip=1:length(TDout)]) && error("output time > modeling time")

	#! no modeling if source wavelet is zero
	#if(maxval(abs(src_wavelets)) .lt. tiny(rzero_de)) 
	#        return
	#endif

	# all the propagating wavefields should have same supersources? check that?

	# check dimension of model

	# check if all sources are receivers are inside medium
	any(.![(ageom[ip] ∈ medium.mgrid) for ip=1:npw]) ? error("sources or receivers not inside medium") : nothing


	length(ageom) != npw ? error("ageom size") : nothing
	length(srcwav) != npw ? error("srcwav size") : nothing
	all([issimilar(ageom[ip],srcwav[ip]) for ip=1:npw]) ? nothing : error("ageom and srcwav mismatch") 

	# necessary that nss and fields should be same for all nprop
	nss = length(ageom[1]);
	sfields=[names(srcwav[ipw][1].d)[1] for ipw in 1:npw]
	isfields = [Array{Int}(undef,length(sfields[ipw])) for ipw in 1:npw]
	#
	fill(nss, npw) != [length(ageom[ip]) for ip=1:npw] ? error("different supersources") : nothing

	#(verbose) &&	println(string("\t> number of super sources:\t",nss))	

	# find maximum and minimum frequencies in the source wavelets
	freqmin = Utils.findfreq(srcwav[1][1].d[1][:,1],srcwav[1][1].grid,attrib=:min) 
	freqmax = Utils.findfreq(srcwav[1][1].d[1][:,1],srcwav[1][1].grid,attrib=:max) 
	freqpeak = Utils.findfreq(srcwav[1][1].d[1][:,1],srcwav[1][1].grid,attrib=:peak) 

	# minimum and maximum velocities
	vpmin = minimum(broadcast(minimum,[medium.bounds[:vp]]))
	vpmax = maximum(broadcast(maximum,[medium.bounds[:vp]]))
	#verbose && println("\t> minimum and maximum velocities:\t",vpmin,"\t",vpmax)

	check_fd_stability(medium.bounds, medium.mgrid, tgrid, freqmin, freqmax, verbose, 5, 0.5)

	# where to store the boundary values (careful, born scaterrers cannot be inside these!?)
	ibx0=npml-2; ibx1=length(medium.mgrid[2])+npml+3
	ibz0=npml-2; ibz1=length(medium.mgrid[1])+npml+3
#	ibx0=npml+1; ibx1=length(medium.mgrid[2])+npml
#	ibz0=npml+1; ibz1=length(medium.mgrid[1])+npml
#	println("**** Boundary Storage Changed **** ")

	# for snaps
	isx0, isz0=npml, npml

	bindices=NamedArray([ibx0,ibx1,ibz0,ibz1,isx0,isz0],([:bx0,:bx1,:bz0,:bz1,:sx0,:sz0],))

	# extend mediums in the PML layers
	exmedium = Medium_pml_pad_trun(medium, nlayer_rand, npml);
	if(typeof(attrib_mod)==FdtdAcouBorn)
		(npw≠2) && error("born modeling needs npw=2")
	end

	#create some aliases
	nz, nx = length.(exmedium.mgrid)
	nzd, nxd = length.(medium.mgrid)
	nt=length(tgridmod)

	fc=get_fc(medium,tgrid,attrib_mod)

	mod,δmod=get_mod(exmedium,attrib_mod)

	δmodall = zeros(2*nzd*nxd)

	# PML
	pml=get_pml(exmedium.mgrid,abs_trbl,step(tgrid),npml-3,vpmin,vpmax,freqpeak)

	# initialize gradient arrays
	gradient=zeros(2*nzd*nxd)
	grad_modtt_stack=SharedMatrix{Float64}(zeros(nz,nx))
	# these are full size, as rhoI -> rhovx and rhovz is also full size
	grad_modrrvx_stack=SharedMatrix{Float64}(zeros(nz,nx))
	grad_modrrvz_stack=SharedMatrix{Float64}(zeros(nz,nx))
	grad_modrr_stack=SharedMatrix{Float64}(zeros(nz,nx))

	grad_mod=NamedArray([grad_modtt_stack, grad_modrrvx_stack, grad_modrrvz_stack,grad_modrr_stack], 
	    ([:tt,:rrvx,:rrvz,:rr],))
	illum_stack=SharedMatrix{Float64}(zeros(nzd, nxd))

	itsnaps = [argmin(abs.(tgridmod .- tsnaps[i])) for i in 1:length(tsnaps)]

	nrmat=[ageom[ipw][iss].nr for ipw in 1:npw, iss in 1:nss]
	datamat=SharedArray{Float64}(nt,maximum(nrmat),nss)
	data=[Records(tgridmod,ageom[ip],rfields) for ip in 1:length(findall(!iszero, rflags))]

	# default is all prpagating wavefields are active
	activepw=[ipw for ipw in 1:npw]
	
	# inititalize viscoelastic/ viscoacoustic parameters here
	if(typeof(attrib_mod)==FdtdAcouVisco)
		nsls=Int32(3)
		exmedium.ic=vcat(exmedium.ic,NamedArray([nsls], ([:nsls],)))
		exmedium.fc=vcat(exmedium.fc,NamedArray(2*pi .* [freqmin, freqmax], ([:freqmin,:freqmax],)))
		memcoeff1, memcoeff2=get_memcoeff(exmedium)
	else
		# dont need visco parameters
		nsls=Int32(0) 
		memcoeff1=zeros(1,1,1)
		memcoeff2=zeros(1,1,1)
	end

	pac=P_common(jobname,attrib_mod,activepw,
	    exmedium,medium,
	    ageom,srcwav,abs_trbl,sfields,isfields,sflags,
	    rfields,rflags,
	    fc,
	    NamedArray([nx,nz,nt,nsls,npw],([:nx,:nz,:nt,:nsls,:npw],)),
	    pml,
	    mod,
	    NamedArray([memcoeff1,memcoeff2],([:memcoeff1,:memcoeff2],)),
	    δmod,
	    δmodall,
	    gradient,
	    grad_mod,
	    illum_flag,illum_stack,
	    backprop_flag,
	    snaps_flag,
	    itsnaps,
	    gmodel_flag,
	    bindices,
	    datamat,
	    data,
	    verbose)	

	# dividing the supersources to workers
	if(nworker===nothing)
		nworker = min(nss, Distributed.nworkers())
	end
	work = Distributed.workers()[1:nworker]
	ssi=[round(Int, s) for s in range(0,stop=nss,length=nworker+1)]
	sschunks=Array{UnitRange{Int64}}(undef, nworker)
	for ib in 1:nworker       
		sschunks[ib]=ssi[ib]+1:ssi[ib+1]
	end

	# a distributed array of P_x_worker --- note that the parameters for each super source are efficiently distributed here
	papa=ddata(T=P_x_worker, init=I->P_x_worker(sschunks[I...][1],pac), pids=work);

	return PFdtd(sschunks, papa, pac)
end

"""
get some integer constants to store them in pac, e.g., model sizes
"""
function get_ic(medium,tgrid,::Union{FdtdAcou,FdtdAcouBorn,FdtdAcouVisco})
	
end

"""
get some floats constants to store then in pac, e.g, spatial sampling
"""
function get_fc(medium,tgrid,::FdtdOld)
	δx, δz = step(medium.mgrid[2]), step(medium.mgrid[1])
	δx24I, δz24I = inv(δx * 24.0), inv(δz * 24.0)
	δxI, δzI = inv(δx), inv(δz)
	δt = step(tgrid)
	δtI = inv(δt)

	fc=NamedArray( [δt, δxI, δzI, δtI, δx24I, δz24I], ([:δt, :δxI, :δzI, :δtI, :δx24I, :δz24I],))
end


"""
extract vectors used 
"""
function get_mod(medium,::FdtdOld)
	nz,nx=length.(medium.mgrid)


	"density values on vx and vz stagerred grids"
	modrr=copy(medium[:rhoI])
	modrrvx = get_rhovxI(modrr)
	modrrvz = get_rhovzI(modrr)

	modttI = copy(medium[:K]) 
	modtt = copy(medium[:KI])
	
	# medium perturbation vectors are required on full space
	δmodtt = zeros(nz, nx)
	δmodrr = zeros(nz, nx)
	δmodrrvx = zeros(nz, nx)
	δmodrrvz = zeros(nz, nx)

	# model arrays inside 
	mod=NamedArray([modtt, modttI,modrr,modrrvx,modrrvz], ([:tt,:ttI,:rr,:rrvx,:rrvz],))
	δmod=NamedArray([δmodtt,δmodrr,δmodrrvx,δmodrrvz], ([:tt,:rr,:rrvx,:rrvz],))

	return mod,δmod

end


"""
Create modeling parameters for each worker.
Each worker performs the modeling of supersources in `sschunks`.
The parameters common to all workers are stored in `pac`.
"""
function P_x_worker_x_pw(ipw, sschunks::UnitRange{Int64},pac::T) where T<:P_common{<:FdtdOld}
	nx=pac.ic[:nx]; nz=pac.ic[:nz]; npw=pac.ic[:npw]

	born_svalue_stack = zeros(nz, nx)

	fields=[:p,:vx,:vz]

	w2=NamedArray([NamedArray([zeros(nz,nx) for i in fields], (fields,)) for i in 1:5], ([:t, :tp, :tpp, :dx, :dz],))

	if(typeof(pac.attrib_mod)==FdtdAcouVisco)
		w3=NamedArray([NamedArray([zeros(pac.ic[:nsls],nz,nx) for i in [:r]], ([:r],)) for i in 1:2], ([:t, :tp],))
	else
		# dummy
		w3=NamedArray([NamedArray([zeros(1,1,1) for i in [:r]], ([:r],)) for i in 1:2], ([:t, :tp],))
	end

	pml_fields=[:dvxdx, :dvzdz, :dpdz, :dpdx]

	memory_pml=NamedArray([zeros(nz,nx) for i in pml_fields], (pml_fields,))

	ss=[P_x_worker_x_pw_x_ss(ipw, iss, pac) for (issp,iss) in enumerate(sschunks)]

	return P_x_worker_x_pw(ss,w2,w3,memory_pml,born_svalue_stack)
end

function Vector{P_x_worker_x_pw}(sschunks::UnitRange{Int64},pac::P_common)
	return [P_x_worker_x_pw(ipw,sschunks,pac) for ipw in 1:pac.ic[:npw]]
end

"""
Create modeling parameters for each supersource. 
Every worker mediums one or more supersources.
"""
function P_x_worker_x_pw_x_ss(ipw, iss::Int64, pac::T) where T<: P_common{<:FdtdOld}

	rfields=pac.rfields
	sfields=pac.sfields
	nt=pac.ic[:nt]
	nx=pac.ic[:nx]; nz=pac.ic[:nz]
	nzd,nxd=length.(pac.medium.mgrid)
	ageom=pac.ageom
	srcwav=pac.srcwav
	sflags=pac.sflags
	mesh_x, mesh_z = pac.exmedium.mgrid[2], pac.exmedium.mgrid[1]

	# records_output, distributed array among different procs
	records = NamedArray([zeros(nt,pac.ageom[ipw][iss].nr) for i in 1:length(rfields)], (rfields,))

	# gradient outputs
	grad_modtt = zeros(nz, nx)
	grad_modrrvx = zeros(nz, nx)
	grad_modrrvz = zeros(nz, nx)


	# saving illum
	illum =  (pac.illum_flag) ? zeros(nz, nx) : zeros(1,1)

	snaps = (pac.snaps_flag) ? zeros(nzd,nxd,length(pac.itsnaps)) : zeros(1,1,1)

	# source wavelets
	wavelets = [NamedArray([zeros(pac.ageom[ipw][iss].ns) for i in 1:length(sfields[ipw])],(sfields[ipw],)) for it in 1:nt]
	fill_wavelets!(ipw, iss, wavelets, srcwav, sflags)

	# storing boundary values for back propagation
	nz1, nx1=length.(pac.medium.mgrid)
	if(pac.backprop_flag ≠ 0)
		boundary=[zeros(3,nx1+6,nt),
		  zeros(nz1+6,3,nt),
		  zeros(3,nx1+6,nt),
		  zeros(nz1+6,3,nt),
		  zeros(nz1+2*npml,nx1+2*npml,3)]
	else
		boundary=[zeros(1,1,1) for ii in 1:5]
	end

	coords=[:x1,:x2,:z1,:z2]

	is=NamedArray([zeros(Int64,ageom[ipw][iss].ns) for i in coords], (coords,))
	# source_spray_weights per supersource
	ssprayw = zeros(4,ageom[ipw][iss].ns)
	# denomsI = zeros(ageom[ipw][iss].ns)

	sindices=NamedArray([zeros(Int64,ageom[ipw][iss].ns) for i in coords], (coords,))
	
	# receiver interpolation weights per sequential source
	rinterpolatew = zeros(4,ageom[ipw][iss].nr)
	# denomrI = zeros(ageom[ipw][iss].nr)
	rindices=NamedArray([zeros(Int64,ageom[ipw][iss].nr) for i in coords], (coords,))

	pass=P_x_worker_x_pw_x_ss(iss,wavelets,ssprayw,records,rinterpolatew,
			   sindices,rindices, boundary,snaps,illum,# grad_modtt,grad_modrrvx,grad_modrrvz)
			   NamedArray([grad_modtt,grad_modrrvx,grad_modrrvz],([:tt,:rrvx,:rrvz],)))

    # update acquisition
	update!(pass,ipw,iss,ageom[ipw][iss],pac)
	return pass
end



include("source.jl")
include("receiver.jl")
include("advance_acou2D.jl")
include("rho_projection.jl")
include("gradient.jl")
include("born.jl")
include("boundary.jl")
include("gallery.jl")


# update TDout after forming a vector and resampling
#	ipropout=0;
#	for iprop in 1:pac.ic[:npw]
#		if(pac.rflags[iprop] ≠ 0)
#			ipropout += 1
##			Records.TD_resamp!(pac.data[ipropout], Records.TD_urpos((Array(records[:,:,iprop,:,:])), rfields, tgridmod, ageom[iprop],
##				ageom_urpos[1].nr[1],
##				(ageom_urpos[1].r[:z][1], ageom_urpos[1].r[:x][1])
##				)) 
#		end
#	end
	# return without resampling for testing
	#return [Records.TD(reshape(records[1+(iprop-1)*nd : iprop*nd],tgridmod.nx,recv_n,nss),
	#		       tgridmod, ageom[1]) for iprop in 1:npw]

function stack_illums!(pac::P_common, pap::P_x_worker)
	nx, nz=pac.ic[:nx], pac.ic[:nz]
	illums=pac.illum_stack
	pass=pap[1].ss
	for issp in 1:length(pass)
		gs=pass[issp].illum
		gss=view(gs,npml+1:nz-npml,npml+1:nx-npml)
		@. illums += gss
	end
end



# modelling for each worker
function mod_x_proc!(pac::P_common, pap::P_x_worker) 
	# source_loop
	for issp in 1:length(pap[1].ss) # note, all npw have same sources
		reset_w2!(pap)

		iss=pap[1].ss[issp].iss # same note as above

		# only for first propagating wavefield, i.e., pap[1]
		if(pac.backprop_flag==-1)
			"initial conditions from boundary for first propagating field only"
			boundary_force_snap_p!(issp,pac,pap)
			boundary_force_snap_vxvz!(issp,pac,pap)
		end

		prog = Progress(pac.ic[:nt], dt=1, desc="\tmodeling supershot $iss/$(length(pac.ageom[1])) ", 
		  		color=:white) 
		# time_loop
		"""
		* don't use shared arrays inside this time loop, for speed when using multiple procs
		"""
		for it=1:pac.ic[:nt]

			pac.verbose && next!(prog, :white)

			advance!(pac,pap)
		
			# force p[1] on boundaries, only for ipw=1
			(pac.backprop_flag==-1) && boundary_force!(it,issp,pac,pap)
	 
			add_source!(it, issp, iss, pac, pap, Source_B1())

			# no born flag for adjoint modelling
			if(!pac.gmodel_flag)
				(typeof(pac.attrib_mod)==FdtdAcouBorn) && add_born_sources!(issp, pac, pap)
			end

			# record boundaries after time reversal already
			(pac.backprop_flag==1) && boundary_save!(pac.ic[:nt]-it+1,issp,pac,pap)

			record!(it, issp, iss, pac, pap, Receiver_B1())

			(pac.gmodel_flag) && compute_gradient!(issp, pac, pap)

			(pac.illum_flag) && compute_illum!(issp, pap)

			if(pac.snaps_flag)
				iitsnaps=findall(x->==(x,it),pac.itsnaps)
				for itsnap in iitsnaps
					snaps_save!(itsnap,issp,pac,pap)
				end
			end

		end # time_loop
		"now pressure is at [nt], velocities are at [nt-1/2]"	

		"one more propagating step to save pressure at [nt+1] -- for time revarsal"
		advance!(pac,pap)

		"save last snap of pressure field"
		(pac.backprop_flag==1) && boundary_save_snap_p!(issp,pac,pap)

		"one more propagating step to save velocities at [nt+3/2] -- for time reversal"
		advance!(pac,pap)

		"save last snap of velocity fields with opposite sign for adjoint propagation"
		(pac.backprop_flag==1) && boundary_save_snap_vxvz!(issp,pac,pap)

		"scale gradients for each issp"
		(pac.gmodel_flag) && scale_gradient!(issp, pap, step(pac.medium.mgrid[2])*step(pac.medium.mgrid[1]))
		

	end # source_loop
end # mod_x_shot




# Need illumination to estimate the approximate diagonal of Hessian
@inbounds @fastmath function compute_illum!(issp::Int64,  pap::P_x_worker)
	# saving illumination to be used as preconditioner 
	p=pap[1].w2[:t][:p]
	illum=pap[1].ss[issp].illum
	for i in eachindex(illum)
		illum[i] += abs2(p[i])
	end
end


@fastmath @inbounds function snaps_save!(itsnap::Int64,issp::Int64,pac::P_common,pap::P_x_worker)
	isx0=pac.bindices[:sx0]
	isz0=pac.bindices[:sz0]
	p=pap[1].w2[:t][:p]
	snaps=pap[1].ss[issp].snaps
	for ix=1:size(snaps,2)
		@simd for iz=1:size(snaps,1)
			snaps[iz,ix,itsnap]=p[isz0+iz,isx0+ix]
		end
	end
end



include("cpml.jl")
include("stability.jl")
include("updates.jl")
include("getprop.jl")

