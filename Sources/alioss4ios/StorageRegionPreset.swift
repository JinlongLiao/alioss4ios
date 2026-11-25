// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 预置沿用 Android 的 OssRegions.kt 与 S3RegionOption.kt，保持供应商区域独立。
struct StorageRegionPreset {
    let code: String
    let endpoint: String?
    let labelKey: String

    /// 选择 OSS 地域时更新空白或标准公网端点，保留自定义地址。
    func apply(to profile: inout StorageProfile) {
        profile.region = code
        if let endpoint, profile.endpoint.isEmpty || Self.isStandardOSSEndpoint(profile.endpoint) {
            profile.endpoint = endpoint
        }
    }

    /// 仅匹配无端口、无部署 path 的标准 HTTPS 端点。
    private static func isStandardOSSEndpoint(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return oss.contains { preset in
            guard let endpoint = preset.endpoint else { return false }
            return normalized == endpoint || normalized == endpoint + "/"
        }
    }

    /// Android 当前 OSS 区域选项，按同一顺序展示。
    static let oss: [Self] = [
        Self(code: "cn-hangzhou", endpoint: "https://oss-cn-hangzhou.aliyuncs.com",
             labelKey: "oss_region_cn_hangzhou"),
        Self(code: "cn-shanghai", endpoint: "https://oss-cn-shanghai.aliyuncs.com",
             labelKey: "oss_region_cn_shanghai"),
        Self(code: "cn-qingdao", endpoint: "https://oss-cn-qingdao.aliyuncs.com",
             labelKey: "oss_region_cn_qingdao"),
        Self(code: "cn-beijing", endpoint: "https://oss-cn-beijing.aliyuncs.com",
             labelKey: "oss_region_cn_beijing"),
        Self(code: "cn-zhangjiakou", endpoint: "https://oss-cn-zhangjiakou.aliyuncs.com",
             labelKey: "oss_region_cn_zhangjiakou"),
        Self(code: "cn-huhehaote", endpoint: "https://oss-cn-huhehaote.aliyuncs.com",
             labelKey: "oss_region_cn_huhehaote"),
        Self(code: "cn-wulanchabu", endpoint: "https://oss-cn-wulanchabu.aliyuncs.com",
             labelKey: "oss_region_cn_wulanchabu"),
        Self(code: "cn-shenzhen", endpoint: "https://oss-cn-shenzhen.aliyuncs.com",
             labelKey: "oss_region_cn_shenzhen"),
        Self(code: "cn-heyuan", endpoint: "https://oss-cn-heyuan.aliyuncs.com",
             labelKey: "oss_region_cn_heyuan"),
        Self(code: "cn-guangzhou", endpoint: "https://oss-cn-guangzhou.aliyuncs.com",
             labelKey: "oss_region_cn_guangzhou"),
        Self(code: "cn-chengdu", endpoint: "https://oss-cn-chengdu.aliyuncs.com",
             labelKey: "oss_region_cn_chengdu"),
        Self(code: "cn-wuhan-lr", endpoint: "https://oss-cn-wuhan-lr.aliyuncs.com",
             labelKey: "oss_region_cn_wuhan_lr"),
        Self(code: "cn-zhongwei", endpoint: "https://oss-cn-zhongwei.aliyuncs.com",
             labelKey: "oss_region_cn_zhongwei"),
        Self(code: "cn-hongkong", endpoint: "https://oss-cn-hongkong.aliyuncs.com",
             labelKey: "oss_region_cn_hongkong"),
        Self(code: "ap-northeast-1", endpoint: "https://oss-ap-northeast-1.aliyuncs.com",
             labelKey: "oss_region_ap_northeast_1"),
        Self(code: "ap-northeast-2", endpoint: "https://oss-ap-northeast-2.aliyuncs.com",
             labelKey: "oss_region_ap_northeast_2"),
        Self(code: "ap-southeast-1", endpoint: "https://oss-ap-southeast-1.aliyuncs.com",
             labelKey: "oss_region_ap_southeast_1"),
        Self(code: "ap-southeast-3", endpoint: "https://oss-ap-southeast-3.aliyuncs.com",
             labelKey: "oss_region_ap_southeast_3"),
        Self(code: "ap-southeast-5", endpoint: "https://oss-ap-southeast-5.aliyuncs.com",
             labelKey: "oss_region_ap_southeast_5"),
        Self(code: "ap-southeast-6", endpoint: "https://oss-ap-southeast-6.aliyuncs.com",
             labelKey: "oss_region_ap_southeast_6"),
        Self(code: "ap-southeast-7", endpoint: "https://oss-ap-southeast-7.aliyuncs.com",
             labelKey: "oss_region_ap_southeast_7"),
        Self(code: "ap-southeast-8", endpoint: "https://oss-ap-southeast-8.aliyuncs.com",
             labelKey: "oss_region_ap_southeast_8"),
        Self(code: "eu-central-1", endpoint: "https://oss-eu-central-1.aliyuncs.com",
             labelKey: "oss_region_eu_central_1"),
        Self(code: "eu-west-1", endpoint: "https://oss-eu-west-1.aliyuncs.com",
             labelKey: "oss_region_eu_west_1"),
        Self(code: "eu-west-2", endpoint: "https://oss-eu-west-2.aliyuncs.com",
             labelKey: "oss_region_eu_west_2"),
        Self(code: "us-west-1", endpoint: "https://oss-us-west-1.aliyuncs.com",
             labelKey: "oss_region_us_west_1"),
        Self(code: "us-east-1", endpoint: "https://oss-us-east-1.aliyuncs.com",
             labelKey: "oss_region_us_east_1"),
        Self(code: "na-south-1", endpoint: "https://oss-na-south-1.aliyuncs.com",
             labelKey: "oss_region_na_south_1"),
        Self(code: "sa-east-1", endpoint: "https://oss-sa-east-1.aliyuncs.com",
             labelKey: "oss_region_sa_east_1"),
        Self(code: "me-east-1", endpoint: "https://oss-me-east-1.aliyuncs.com",
             labelKey: "oss_region_me_east_1"),
    ]

    /// Android 当前 S3 区域选项，按同一顺序展示。
    static let s3: [Self] = [
        Self(code: "ap-northeast-1", endpoint: nil,
             labelKey: "s3_region_ap_northeast_1"),
        Self(code: "ap-southeast-1", endpoint: nil,
             labelKey: "s3_region_ap_southeast_1"),
        Self(code: "ap-east-1", endpoint: nil,
             labelKey: "s3_region_ap_east_1"),
        Self(code: "us-east-1", endpoint: nil,
             labelKey: "s3_region_us_east_1"),
        Self(code: "us-west-2", endpoint: nil,
             labelKey: "s3_region_us_west_2"),
        Self(code: "af-south-1", endpoint: nil,
             labelKey: "s3_region_af_south_1"),
        Self(code: "ap-east-2", endpoint: nil,
             labelKey: "s3_region_ap_east_2"),
        Self(code: "ap-northeast-2", endpoint: nil,
             labelKey: "s3_region_ap_northeast_2"),
        Self(code: "ap-northeast-3", endpoint: nil,
             labelKey: "s3_region_ap_northeast_3"),
        Self(code: "ap-south-1", endpoint: nil,
             labelKey: "s3_region_ap_south_1"),
        Self(code: "ap-south-2", endpoint: nil,
             labelKey: "s3_region_ap_south_2"),
        Self(code: "ap-southeast-2", endpoint: nil,
             labelKey: "s3_region_ap_southeast_2"),
        Self(code: "ap-southeast-3", endpoint: nil,
             labelKey: "s3_region_ap_southeast_3"),
        Self(code: "ap-southeast-4", endpoint: nil,
             labelKey: "s3_region_ap_southeast_4"),
        Self(code: "ap-southeast-5", endpoint: nil,
             labelKey: "s3_region_ap_southeast_5"),
        Self(code: "ap-southeast-6", endpoint: nil,
             labelKey: "s3_region_ap_southeast_6"),
        Self(code: "ap-southeast-7", endpoint: nil,
             labelKey: "s3_region_ap_southeast_7"),
        Self(code: "ca-central-1", endpoint: nil,
             labelKey: "s3_region_ca_central_1"),
        Self(code: "ca-west-1", endpoint: nil,
             labelKey: "s3_region_ca_west_1"),
        Self(code: "cn-north-1", endpoint: nil,
             labelKey: "s3_region_cn_north_1"),
        Self(code: "cn-northwest-1", endpoint: nil,
             labelKey: "s3_region_cn_northwest_1"),
        Self(code: "eu-central-1", endpoint: nil,
             labelKey: "s3_region_eu_central_1"),
        Self(code: "eu-central-2", endpoint: nil,
             labelKey: "s3_region_eu_central_2"),
        Self(code: "eu-north-1", endpoint: nil,
             labelKey: "s3_region_eu_north_1"),
        Self(code: "eu-south-1", endpoint: nil,
             labelKey: "s3_region_eu_south_1"),
        Self(code: "eu-south-2", endpoint: nil,
             labelKey: "s3_region_eu_south_2"),
        Self(code: "eu-west-1", endpoint: nil,
             labelKey: "s3_region_eu_west_1"),
        Self(code: "eu-west-2", endpoint: nil,
             labelKey: "s3_region_eu_west_2"),
        Self(code: "eu-west-3", endpoint: nil,
             labelKey: "s3_region_eu_west_3"),
        Self(code: "il-central-1", endpoint: nil,
             labelKey: "s3_region_il_central_1"),
        Self(code: "me-central-1", endpoint: nil,
             labelKey: "s3_region_me_central_1"),
        Self(code: "me-south-1", endpoint: nil,
             labelKey: "s3_region_me_south_1"),
        Self(code: "mx-central-1", endpoint: nil,
             labelKey: "s3_region_mx_central_1"),
        Self(code: "sa-east-1", endpoint: nil,
             labelKey: "s3_region_sa_east_1"),
        Self(code: "us-east-2", endpoint: nil,
             labelKey: "s3_region_us_east_2"),
        Self(code: "us-west-1", endpoint: nil,
             labelKey: "s3_region_us_west_1"),
        Self(code: "us-gov-east-1", endpoint: nil,
             labelKey: "s3_region_us_gov_east_1"),
        Self(code: "us-gov-west-1", endpoint: nil,
             labelKey: "s3_region_us_gov_west_1"),
    ]
}
