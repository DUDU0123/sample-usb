//package com.felhr.deviceids;
//
//import static com.felhr.deviceids.Helpers.createTable;
//
//import static com.felhr.deviceids.Helpers.createDevice;
//
//public class PL2303GIds
//{
//    private PL2303GIds()
//    {
//
//    }
//
//    private static final long[] pl2303GDevices = createTable(
//            createDevice(0x067b, 0x23a3)
//    );
//
//    public static boolean isDeviceSupported(int vendorId, int productId)
//    {
//        return Helpers.exists(pl2303GDevices, vendorId, productId);
//    }
//}