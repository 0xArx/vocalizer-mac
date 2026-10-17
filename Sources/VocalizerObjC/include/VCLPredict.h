// Core ML prediction that turns Objective-C exceptions into NSErrors.
// Core ML occasionally raises an NSException from inside -predictionFromFeatures:options:error:
// (seen: MLE5BindEmptyMemoryObjectToPort after hours of Neural Engine use). Swift cannot catch those,
// so the call is made here, with no Swift frames between the throw and the @catch.
#import <CoreML/CoreML.h>

NS_ASSUME_NONNULL_BEGIN

id<MLFeatureProvider> _Nullable VCLPredict(MLModel *model, id<MLFeatureProvider> input,
                                           MLPredictionOptions *options, NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
