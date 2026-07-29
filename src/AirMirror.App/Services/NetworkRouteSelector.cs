using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace AirMirror.App.Services;

internal sealed record NetworkRouteSelection(IPAddress Address, string InterfaceName);

internal static class NetworkRouteSelector
{
    private static readonly IPEndPoint RouteProbeEndpoint = new(IPAddress.Parse("192.0.2.1"), 9);

    public static NetworkRouteSelection? FindPreferredIpv4()
    {
        var routedAddress = ProbeDefaultRoute();
        if (routedAddress is not null)
        {
            return new NetworkRouteSelection(
                routedAddress,
                FindInterfaceName(routedAddress) ?? "default network adapter");
        }

        return FindGatewayFallback();
    }

    private static IPAddress? ProbeDefaultRoute()
    {
        try
        {
            using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            socket.Connect(RouteProbeEndpoint);
            return socket.LocalEndPoint is IPEndPoint endpoint && IsUsable(endpoint.Address)
                ? endpoint.Address
                : null;
        }
        catch (SocketException)
        {
            return null;
        }
    }

    private static NetworkRouteSelection? FindGatewayFallback()
    {
        var candidates = new List<(NetworkRouteSelection Selection, int Score)>();
        foreach (var network in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (network.OperationalStatus != OperationalStatus.Up ||
                network.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
            {
                continue;
            }

            IPInterfaceProperties properties;
            try
            {
                properties = network.GetIPProperties();
            }
            catch (NetworkInformationException)
            {
                continue;
            }

            var hasIpv4Gateway = properties.GatewayAddresses.Any(gateway =>
                gateway.Address.AddressFamily == AddressFamily.InterNetwork &&
                !gateway.Address.Equals(IPAddress.Any));
            var adapterDescription = $"{network.Name} {network.Description}";
            var isVirtual = adapterDescription.Contains("virtual", StringComparison.OrdinalIgnoreCase) ||
                            adapterDescription.Contains("host-only", StringComparison.OrdinalIgnoreCase) ||
                            adapterDescription.Contains("wi-fi direct", StringComparison.OrdinalIgnoreCase) ||
                            adapterDescription.Contains("vpn", StringComparison.OrdinalIgnoreCase);

            foreach (var unicast in properties.UnicastAddresses)
            {
                if (!IsUsable(unicast.Address))
                {
                    continue;
                }

                var score = (hasIpv4Gateway ? 1_000 : 0) +
                            (network.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.Wireless80211 ? 100 : 0) -
                            (isVirtual ? 500 : 0);
                candidates.Add((new NetworkRouteSelection(unicast.Address, network.Name), score));
            }
        }

        return candidates
            .OrderByDescending(candidate => candidate.Score)
            .Select(candidate => candidate.Selection)
            .FirstOrDefault();
    }

    private static string? FindInterfaceName(IPAddress address)
    {
        foreach (var network in NetworkInterface.GetAllNetworkInterfaces())
        {
            try
            {
                if (network.GetIPProperties().UnicastAddresses.Any(unicast => unicast.Address.Equals(address)))
                {
                    return network.Name;
                }
            }
            catch (NetworkInformationException)
            {
                // An adapter can disappear while Windows is enumerating it.
            }
        }

        return null;
    }

    private static bool IsUsable(IPAddress address)
    {
        if (address.AddressFamily != AddressFamily.InterNetwork ||
            address.Equals(IPAddress.Any) ||
            address.Equals(IPAddress.None) ||
            IPAddress.IsLoopback(address))
        {
            return false;
        }

        var bytes = address.GetAddressBytes();
        return bytes[0] != 0 && !(bytes[0] == 169 && bytes[1] == 254);
    }
}
