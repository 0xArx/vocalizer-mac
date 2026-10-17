#import "VCLPredict.h"

id<MLFeatureProvider> _Nullable VCLPredict(MLModel *model, id<MLFeatureProvider> input,
                                           MLPredictionOptions *options, NSError * _Nullable * _Nullable error) {
    @try {
        return [model predictionFromFeatures:input options:options error:error];
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"(no reason)"];
            *error = [NSError errorWithDomain:@"VocalizerCoreMLException" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return nil;
    }
}
