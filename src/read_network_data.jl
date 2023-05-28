#-----------------------------------------------------------------------------
#
#                           - TFE : Bilevel DNEP - 
#                             University of Liege
#
#-----------------------------------------------------------------------------
# Created By  : Manon Cornet
# Created Date: Saturday March 20 2023
#
# utils:
#   File containing the function required to read the data required to launch 
#   a simulation of the bilevel model
#
# =============================================================================
#                                   Imports
# =============================================================================
import DataFrames
import Random 
import XLSX

# =============================================================================
#                                  Functions
# =============================================================================
""" define_pu_basis 

    Arguments:
    ----------
        - BASE_POWER   : value of the base power in MW
        - BASE_VOLTAGE : value of the base voltage in kV
        - BASE_MONEY   : value of the base money in kA
    
    Return value:
    -------------
        - A named tuple containing the pu basis
"""
function define_pu_basis(;BASE_POWER::Float64 = 1.0, 
                        BASE_VOLTAGE::Float64 = 34.5
                        )
    
    BASE_CURRENT = BASE_POWER / BASE_VOLTAGE      # [kA]
    BASE_IMPEDANCE = BASE_VOLTAGE / BASE_CURRENT  # [Ohm]

    pu_basis = (base_power=BASE_POWER, 
                base_voltage=BASE_VOLTAGE,
                base_current=BASE_CURRENT, 
                base_impedance=BASE_IMPEDANCE
                )
                
    return pu_basis 
end

""" get_buses_data 

    Arguments:
    ----------
        - NETWORK_PATH   : path of xlsx file contrainint the network data
        - voltage_limits : limits on the bus voltage
        - pu_basis       : named tuple containing the per-unit basis used for the simulation
    
    Return value:
    -------------
        - A structure of type Network that contains the network data
"""
function get_buses_data(NETWORK_PATH::String, V_limits::VLIM, pu_basis::PU_BASIS, max_pv_capa::Float64)
    # Get the sheet corresponding to network buses data
    df_bus = DataFrames.DataFrame(XLSX.readtable(NETWORK_PATH, "bus"))

    N = DataFrames.nrow(df_bus)            # Total number of buses
    Ns = sum(df_bus.type .== "substation") # Number of substation buses
    Nu = N - Ns                            # Number of user buses

    nodes = [Node(i, (x=convert(Float64, df_bus.x[i]), y=convert(Float64, df_bus.y[i]))) for i in 1:N]
    subs_buses = [Substation(nodes[i], V_limits, convert(Float64, df_bus.S_G_max_mva[i]) / pu_basis.base_power) for i in 1:Ns]
    load_buses = [User(nodes[i], V_limits, max_pv_capa / pu_basis.base_power) for i in Ns+1:N]

    return nodes, subs_buses, load_buses
end

""" get_lines_data 

    Arguments:
    ----------
        - NETWORK_PATH : path of xlsx file containing the network data
        - nodes        : list containing all the nodes of the network graph
    
    Return values:
    -------------
        - edges: list containing all the edges of the network graph
        - lines: list containing all the electrical lines of the network
"""
function get_lines_data(NETWORK_PATH::String, nodes::Vector{Node})
    # Get the sheet corresponding to network lines data
    df_line = DataFrames.DataFrame(XLSX.readtable(NETWORK_PATH, "line"))

    L = DataFrames.nrow(df_line) # number of lines
    # Get all the edges of the network
    edges = [Edge(l, nodes[df_line.from_bus[l]], nodes[df_line.to_bus[l]]) for l in 1:L]
    # Get all the lines
    lines = [Line(edges[l], convert(Float64, df_line.length_km[l])) for l in 1:L]
    
    return edges, lines
end

""" get_conductors_data 

    Arguments:
    ----------
        - NETWORK_PATH : path of xlsx file containing the network data
        - pu_basis     : named tuple containing the per-unit basis used for the simulation
    
    Return values:
    -------------
        - conds: list of available conductors to build a line
"""
function get_conductors_data(NETWORK_PATH::String, pu_basis::PU_BASIS, money_basis::Float64)
    # Get the sheet corresponding to network buses data
    df_cond = DataFrames.DataFrame(XLSX.readtable(NETWORK_PATH, "conductor"))

    K = DataFrames.nrow(df_cond)    

    conds = [Conductor( df_cond.name[k], 
                        convert(Float64, df_cond.r_ohm_per_km[k]) / pu_basis.base_impedance, 
                        convert(Float64, df_cond.x_ohm_per_km[k]) / pu_basis.base_impedance,
                        convert(Float64, df_cond.max_i_ka[k]) / pu_basis.base_current,
                        convert(Float64, df_cond.cost_kdollars_per_km[k]) / money_basis
                        ) 
            for k in 1:K]

    return conds
end


""" get_network_data 

    Arguments:
    ----------
        - NETWORK_PATH   : path of xlsx file containing the network data
        - voltage_limits : limits on the bus voltage in pu
        - PU_basis       : named tuple containing the per-unit basis used for the simulation
    
    Return values:
    -------------
        - A structure of type Network that contains the network data
        - A structure of type NetworkTopology that contains the topology of the network
"""
function get_network_data(  NETWORK_PATH::String; 
                            voltage_limits::VLIM=(V_min=0.95, V_max=1.05),
                            max_pv_capa::Float64=0.4, 
                            pu_basis::PU_BASIS=define_pu_basis(),
                            money_basis::Float64=1.0
                            )
    
    nodes, subs_buses, load_buses = get_buses_data(NETWORK_PATH, voltage_limits, pu_basis, max_pv_capa)
    edges, lines = get_lines_data(NETWORK_PATH, nodes)
    conductors = get_conductors_data(NETWORK_PATH, pu_basis, money_basis)

    return  Network(lines, subs_buses, load_buses, conductors, pu_basis), 
            NetworkTopology(nodes, edges)
end

function add_load_profiles!(network::Network, load_profiles::Matrix{Float64}; delta_t::Integer, cos_phi::Float64=0.9)
    nb_users = get_nb_load_bus(network)
    _, nb_profiles = size(load_profiles)

    @assert nb_users == nb_profiles
    
    for u in 1:nb_users
        p = Profile(load_profiles[:, u], delta_t)
        network.load_buses[u].load_profile = p
    end
    return 
end

function add_PV_profiles!(  network::Network, 
                            PV_profiles::Matrix{Float64}, 
                            id_users;
                            PQ_diagram::PQ_DIAGRAM,
                            delta_t::Integer)

    nb_users = length(id_users)
    _, nb_profiles = size(PV_profiles)

    @assert nb_users == nb_profiles

    for (index, u) in enumerate(id_users)
        p = Profile(PV_profiles[:, index], delta_t)
        network.load_buses[u].PV_installation = PV(p, PQ_diagram)
    end
    return
end


house_nodeshape(x_i, y_i, s) = 
[
    (x_i + 0.7s * dx, y_i + 0.7s * dy) 
    for (dx, dy) in [(1, 1), (0, 1.6), (-1,1), (-1, -1), (1, -1), (1, 1)]
]

subs_nodeshape(x_i, y_i, s) = [
    (x_i + 0.8s * dx, y_i + 0.8s * dy) 
    for (dx, dy) in [(1, 1), (-1, 1), (-1, -1), (1, -1), (1,1)]
]

# -- Network topology --
function print_network_topology(topology::NetworkTopology; save_graph::Bool=true, show_graph::Bool=true)

    # -- Building the network graph -- 
    g = SimpleDiGraph(get_nb_nodes(topology))

    for e in topology.edges 
        add_edge!(g, e.from_node.id, e.to_node.id)
    end

    # -- Plotting the graph topology --

    #node_shapes = [[subs_nodeshape for _ in Ns];[house_nodeshape for _ in Nu]]
    colors      = ["#689BAA", "#C2C5DB"]
    x_coords = [n.coord.x for n in topology.nodes]
    y_coords = [n.coord.y for n in topology.nodes]

    graph = graphplot( adjacency_matrix(g),
                        x               = x_coords,           # x-coordinate of the nodes
                        y               = y_coords,                                 # y-coordinate of the nodes
                        nodesize        = 0.1,
                        nodestrokewidth = 0,                                        # coutour line width of the node
                        edgestyle       = :solid,
                        nodealpha       = 1,                                        # transparency of node color
                        names           = [L"\textbf{%$(node.id)}" for node in topology.nodes],                        # node label
                        nodeshape       = :rect,                              # :circle, :ellipse, :hexagon
                        nodecolor       = colors[[1 for _ in topology.nodes]],
                        linewidth       = 1,
                        arrow           = false,
                        edgelabel       = Dict((e.from_node.id, e.to_node.id) =>  L"\textbf{%$(e.id)}" for e in topology.edges),
                        axis_buffer     = 0.1,
                        fontsize        = 10,
                        size            = (1200, 1000),
                        edgelabel_offset= 0.1,
                        curves          = false,                                    # if an edge is curved or not
    )

    save_graph && Plots.savefig(graph, "network_topology.pdf")
    show_graph && display(graph)
    return
end

