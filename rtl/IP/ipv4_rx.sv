`timescale 1ns / 1ps
/* This module recieves ethernet payload data as well as ethernet header data
 * in parallel with one another or via AXI-Stream depending on ETH_FRAME. It passes through 
 * the ethernet headers, and inspects the IP payload to determine if the packet is good or bad. 
 * This module checks for the following:
 *  1) IP Payload size = total length field 
 *  2) Checksum field is recalculated based on recieved inputs to see if there is a match
 *  3) IP Version = IPv4
 *  4) Checks the ether type is valid (ARP or IPv4)
 * 
 * For reference, the IP frame is below:
 *  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 *  +---------------+---------------+---------------+---------------+
 *  |Version|  IHL  |     Type      |          Total Length         |
 *  +---------------+---------------+---------------+---------------+
 *  |         Identification        |Flags|     Fragment Offset     |
 *  +---------------+---------------+---------------+---------------+
 *  | Time to Live  |    Protocol   |        Header Checksum        |
 *  +---------------+---------------+---------------+---------------+
 *  |                       Source IP Address                       |
 *  +---------------+---------------+---------------+---------------+
 *  |                    Destination IP Address                     |
 *  +---------------+---------------+---------------+---------------+
 *
 */

module ipv4_rx
#(
    parameter AXI_DATA_WIDTH = 8,
    parameter ETH_FRAME = 1                                     // If ETH_FRAME=1, the AXI-Stream payload contains the 
                                                                // Ethernet header frame 
)(
    input wire i_clk,
    input wire i_reset_n,

    /* Ethernet Header Input */
    input wire s_eth_hdr_valid,
    output wire s_eth_hdr_rdy,
    input wire [47:0] s_eth_rx_src_mac_addr,
    input wire [47:0] s_eth_rx_dst_mac_addr,
    input wire [15:0] s_eth_rx_type,

    /* Ethernet Frame Input */
    input wire [AXI_DATA_WIDTH-1:0] s_rx_axis_tdata,
    input wire s_rx_axis_tvalid,
    input wire s_rx_axis_tlast,
    output wire s_rx_axis_trdy,

    /* IP/Ethernet Frame Outputs */
    input wire m_ip_hdr_trdy,
    output wire m_ip_hdr_tvalid,
    output wire [31:0] m_ip_rx_src_ip_addr,
    output wire [31:0] m_ip_rx_dst_ip_addr,
    output wire [47:0] m_eth_rx_src_mac_addr,
    output wire [47:0] m_eth_rx_dst_mac_addr,
    output wire [15:0] m_eth_rx_type,    

    /* IP Frame Payload */
    output wire [AXI_DATA_WIDTH-1:0] m_rx_axis_tdata,
    output wire m_rx_axis_tvalid,
    output wire m_rx_axis_tlast,
    input wire m_rx_axis_trdy,

    /* Status Flags */
    output wire bad_packet     
);

/* Constant Params */
localparam IPv4_VERSION = 4'd4; 

/* State Encoding */
localparam [2:0] IDLE = 3'b000;
localparam [2:0] ETH_HDR = 3'b001;
localparam [2:0] IP_HDR = 3'b010;
localparam [2:0] PAYLOAD = 3'b011;
localparam [2:0] WAIT = 3'b100;

/* Data Path Registers */
reg [2:0] state = IDLE;
reg [15:0] ip_checksum_fields;
reg [16:0] int_checksum_sum = 17'b0;
reg [15:0] checksum_carry_sum = 16'b0;
reg [AXI_DATA_WIDTH-1:0] m_rx_axis_tdata_reg = {AXI_DATA_WIDTH-1{1'b0}};
reg m_rx_axis_tvalid_reg = 1'b0;
reg m_rx_axis_tlast_reg = 1'b0;
reg s_rx_axis_trdy_reg = 1'b0;
reg bad_pckt_reg = 1'b0;

reg [4:0] hdr_cntr = 5'b0;
reg latched_hdr = 1'b0;

/* Checksum Calculation Logic */ 
reg [15:0] checksum_sum = 16'b0;

/* Ethernet Header Data Path Registers */
reg eth_hdr_rdy_reg = 1'b0;
reg [47:0] eth_rx_src_mac_addr = 48'd0;
reg [47:0] eth_rx_dst_mac_addr = 48'd0;
reg [15:0] eth_rx_type = 16'd0;

/* IP Header Data Path Registers */
reg m_ip_hdr_tvalid_reg = 1'b0;
reg [3:0] ip_hdr_version;
reg [3:0] ip_hdr_length;
reg [7:0] ip_hdr_type;
reg [15:0] ip_hdr_total_length;
reg [15:0] ip_hdr_id;
reg [2:0] ip_hdr_flags;
reg [12:0] ip_hdr_frag_offset;
reg [7:0] ip_hdr_ttl;
reg [7:0] ip_hdr_protocol;
reg [15:0] ip_hdr_checksum;
reg [31:0] ip_hdr_src_ip_addr;                                 
reg [31:0] ip_hdr_dst_ip_addr;  

/* De-encapsulation Logic */
always @(posedge i_clk) begin
    if(!i_reset_n) begin
        state <= IDLE;

        eth_hdr_rdy_reg <= 1'b0;
        m_ip_hdr_tvalid_reg <= 1'b0;
        s_rx_axis_trdy_reg <= 1'b0;
        m_rx_axis_tvalid_reg <= 1'b0;

        bad_pckt_reg <= 1'b0;
        latched_hdr <= 1'b0;
        hdr_cntr <= 5'b0;
    end else begin
        // Default Values
        eth_hdr_rdy_reg <= 1'b0;
        bad_pckt_reg <= 1'b0;
        s_rx_axis_trdy_reg <= 1'b0;
        m_rx_axis_tvalid_reg <= 1'b0;
        m_ip_hdr_tvalid_reg <= 1'b0;

        case(state)
            IDLE: begin

                checksum_carry_sum <= 16'b0;
                int_checksum_sum <= 17'b0;

                ////////////////////////////////////////////////////////////////////////////////////////
                // If ETH_FRAME is set, the AXI data recieved will be directly passed from the ethernet MAC
                // therefore, it will be formatted with the src MAC, dst MAC and ethernet type in front 
                // of the IP packet. In this case, the ethernet header data will not be passed in-parallel
                // and the ethernet header data will be in-front of the IP packet.
                ////////////////////////////////////////////////////////////////////////////////////////
                if(ETH_FRAME) begin
                    eth_hdr_rdy_reg <= 1'b0;
                    
                    if(s_rx_axis_tvalid) begin
                        s_rx_axis_trdy_reg <= 1'b1;
                        hdr_cntr <= 5'b0;
                        state <= ETH_HDR;
                    end
                end else begin
                    eth_hdr_rdy_reg <= 1'b1;

                    // If there is valid data and valid header, latch the ethernet header and shift
                    // to the next state
                    if(s_eth_hdr_valid & s_rx_axis_tvalid) begin
                        eth_rx_src_mac_addr <= s_eth_rx_src_mac_addr;
                        eth_rx_dst_mac_addr <= s_eth_rx_dst_mac_addr;
                        eth_rx_type <= s_eth_rx_type;

                        s_rx_axis_trdy_reg <= 1'b1;
                        eth_hdr_rdy_reg <= 1'b0;
                        hdr_cntr <= 5'b0;
                        state <= IP_HDR;
                    end
                end
            end
            ETH_HDR: begin
                s_rx_axis_trdy_reg <= 1'b1;

                if(s_rx_axis_trdy_reg & s_rx_axis_tvalid) begin

                    hdr_cntr <= hdr_cntr + 1;

                    // Depending on the header counter, the input values will be associated with
                    // specific values of the ethernet header
                    if(hdr_cntr < 4'd6)
                        eth_rx_dst_mac_addr <= {eth_rx_dst_mac_addr[39:0], s_rx_axis_tdata};
                    else if(hdr_cntr < 4'd12)
                        eth_rx_src_mac_addr <= {eth_rx_src_mac_addr[39:0], s_rx_axis_tdata};
                    else if(hdr_cntr < 4'd14) begin
                        eth_rx_type <= {eth_rx_type[7:0], s_rx_axis_tdata};

                        if(hdr_cntr == 4'd13) begin
                            hdr_cntr <= 5'b0;
                            state <= IP_HDR;
                        end
                    end
                            
                end
            end
            IP_HDR: begin
                s_rx_axis_trdy_reg <= 1'b1;

                // AXI-Stream valid handshake
                if(s_rx_axis_trdy_reg & s_rx_axis_tvalid) begin

                    hdr_cntr <= hdr_cntr + 1'b1;
                    
                    // If the number of bytes recieved is even, stage the byte to form a 16-bit word
                    // and calculate the carry for any current intermediary sums.
                    if(hdr_cntr[0] == 1'b0) begin
                        ip_checksum_fields <= {ip_checksum_fields[7:0], s_rx_axis_tdata};
                        checksum_carry_sum <= int_checksum_sum[15:0] + int_checksum_sum[16];
                    end else 
                        int_checksum_sum <= checksum_carry_sum + {ip_checksum_fields[7:0], s_rx_axis_tdata};

                    // Iterate through each byte of the IP header and store the values in the data registers
                    case(hdr_cntr)
                        5'd0: begin
                            // Make sure the packet is an IPv4 packet
                            if(s_rx_axis_tdata[7:4] == IPv4_VERSION) begin
                                ip_hdr_length <= s_rx_axis_tdata[3:0];
                                ip_hdr_version <= s_rx_axis_tdata[7:4];
                            end else
                                state <= WAIT;
                        end
                        5'd1: ip_hdr_type <= s_rx_axis_tdata;
                        5'd2: ip_hdr_total_length[15:8] <= s_rx_axis_tdata;
                        5'd3: ip_hdr_total_length[7:0] <= s_rx_axis_tdata;
                        5'd4: ip_hdr_id[15:8] <= s_rx_axis_tdata;
                        5'd5: ip_hdr_id[7:0] <= s_rx_axis_tdata;
                        5'd6: begin
                            ip_hdr_flags <= s_rx_axis_tdata[7:5];
                            ip_hdr_frag_offset[12:8] <= s_rx_axis_tdata[4:0];
                            // Subtract the total length register from the number of header bytes
                            ip_hdr_total_length <= ip_hdr_total_length - (ip_hdr_length << 2); 
                        end
                        5'd7: ip_hdr_frag_offset[7:0] <= s_rx_axis_tdata;
                        5'd8: ip_hdr_ttl <= s_rx_axis_tdata;
                        5'd9: ip_hdr_protocol <= s_rx_axis_tdata;
                        5'd10: ip_hdr_checksum[15:8] <= s_rx_axis_tdata;
                        5'd11: ip_hdr_checksum[7:0] <= s_rx_axis_tdata;
                        5'd12: ip_hdr_src_ip_addr[31:24] <= s_rx_axis_tdata;
                        5'd13: ip_hdr_src_ip_addr[23:16] <= s_rx_axis_tdata;
                        5'd14: ip_hdr_src_ip_addr[15:8] <= s_rx_axis_tdata;
                        5'd15: ip_hdr_src_ip_addr[7:0] <= s_rx_axis_tdata;    
                        5'd16: ip_hdr_dst_ip_addr[31:24] <= s_rx_axis_tdata;
                        5'd17: ip_hdr_dst_ip_addr[23:16] <= s_rx_axis_tdata;
                        5'd18: ip_hdr_dst_ip_addr[15:8] <= s_rx_axis_tdata;
                        5'd19: ip_hdr_dst_ip_addr[7:0] <= s_rx_axis_tdata;   
                        5'd20: begin
                            s_rx_axis_trdy_reg <= m_rx_axis_trdy;
                            m_ip_hdr_tvalid_reg <= 1'b1;

                            //Store the first raw payload data
                            m_rx_axis_tdata_reg <= s_rx_axis_tdata;
                            m_rx_axis_tvalid_reg <= s_rx_axis_tvalid;
                            m_rx_axis_tlast_reg <= s_rx_axis_tlast;  
                                
                            // Decrement the payload byte counter
                            ip_hdr_total_length <= ip_hdr_total_length - 1'b1;  

                            // If the packet only contained IP/ethernet header info, return to IDLE
                            if(s_rx_axis_tlast & s_rx_axis_tvalid)
                                state <= IDLE; 
                            else                    
                                state <= PAYLOAD;         

                        end                                    
                    endcase            
                end
            end
            PAYLOAD: begin
                m_rx_axis_tvalid_reg <= 1'b1;
                m_ip_hdr_tvalid_reg <= 1'b1;

                // Verify Checksum
                if(checksum_carry_sum != 16'hFFFF) begin
                    bad_pckt_reg <= 1'b1;
                    state <= WAIT;
                end

                // Once the downstream module has read the header data, we can lower the hdr_valid signal
                if(latched_hdr || (m_ip_hdr_trdy & m_ip_hdr_tvalid)) begin
                    m_ip_hdr_tvalid_reg <= 1'b0;
                    latched_hdr <= 1'b1;
                end 

                // If the up-stream module & down-stream module have data/can recieve data
                // we can latch the incoming data
                if(m_rx_axis_trdy & s_rx_axis_tvalid) begin
                    m_rx_axis_tdata_reg <= s_rx_axis_tdata;
                    m_rx_axis_tlast_reg <= s_rx_axis_tlast;

                    // Count the number of bytes recieved
                    ip_hdr_total_length <= ip_hdr_total_length - 1'b1;

                    if(s_rx_axis_tlast & s_rx_axis_tvalid) begin
                        latched_hdr <= 1'b0;

                        // Total bytes in the payload did not match the bytes specified in the IP Header
                        if(ip_hdr_total_length != 16'b1)begin
                            bad_pckt_reg <= 1'b1;
                            state <= WAIT;
                        end

                        state <= IDLE;
                    end
                end

            end
            WAIT: begin
                s_rx_axis_trdy_reg <= 1'b1;
                // Wait until the remainder of the packet has been recieved
                if(s_rx_axis_tlast & s_rx_axis_tvalid) begin
                    s_rx_axis_trdy_reg <= 1'b0;
                    latched_hdr <= 1'b0;
                    state <= IDLE;
                end
            end
        endcase
    end
end

/* Output Modules */
assign s_eth_hdr_rdy = eth_hdr_rdy_reg;
assign s_rx_axis_trdy = (state == PAYLOAD) ? m_rx_axis_trdy : s_rx_axis_trdy_reg;

assign m_rx_axis_tvalid = m_rx_axis_tvalid_reg;
assign m_rx_axis_tdata = m_rx_axis_tdata_reg;
assign m_rx_axis_tlast = m_rx_axis_tlast_reg;
assign bad_packet = bad_pckt_reg;

/* Output Ethernet/IP Header Info */
assign m_ip_hdr_tvalid = m_ip_hdr_tvalid_reg;
assign m_ip_rx_src_ip_addr = ip_hdr_src_ip_addr;
assign m_ip_rx_dst_ip_addr = ip_hdr_dst_ip_addr;
assign m_eth_rx_src_mac_addr = eth_rx_src_mac_addr;
assign m_eth_rx_dst_mac_addr = eth_rx_dst_mac_addr;
assign m_eth_rx_type = eth_rx_type;

endmodule